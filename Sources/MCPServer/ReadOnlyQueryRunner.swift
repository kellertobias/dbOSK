import DBCore
import Foundation

/// Client-adjustable limits on one MCP query, clamped to hard caps so an
/// agent can raise the defaults but never remove the ceiling.
public struct MCPQueryLimits: Sendable {
    public var maxRows: Int
    public var maxBytes: Int
    public var timeoutSeconds: Double

    public static let defaultMaxRows = 100
    public static let defaultMaxBytes = 1_000_000
    public static let defaultTimeoutSeconds = 30.0
    public static let hardMaxRows = 1000
    public static let hardMaxBytes = 5_000_000
    public static let hardTimeoutSeconds = 300.0

    public init(
        maxRows: Int = Self.defaultMaxRows,
        maxBytes: Int = Self.defaultMaxBytes,
        timeoutSeconds: Double = Self.defaultTimeoutSeconds
    ) {
        self.maxRows = maxRows
        self.maxBytes = maxBytes
        self.timeoutSeconds = timeoutSeconds
    }

    public func clamped() -> MCPQueryLimits {
        MCPQueryLimits(
            maxRows: min(max(maxRows, 1), Self.hardMaxRows),
            maxBytes: min(max(maxBytes, 1024), Self.hardMaxBytes),
            timeoutSeconds: min(max(timeoutSeconds, 1), Self.hardTimeoutSeconds))
    }
}

public struct ReadOnlyQueryResult: Sendable {
    public let columns: [ColumnMeta]
    public let rows: [[DBValue]]
    /// True when the row or byte cap cut the result short.
    public let truncated: Bool

    public init(columns: [ColumnMeta], rows: [[DBValue]], truncated: Bool) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
    }
}

public struct MCPQueryTimeout: Error, Sendable, CustomStringConvertible {
    public let seconds: Double
    public var description: String {
        "Query exceeded the \(Int(seconds))s timeout and was cancelled. "
            + "Pass timeout_seconds to allow more time (capped at \(Int(MCPQueryLimits.hardTimeoutSeconds))s)."
    }
}

/// Drains a `QueryExecution` under row/byte caps and a wall-clock timeout,
/// cancelling the server-side query when either cuts it short.
public enum ReadOnlyQueryRunner {

    public static func run(
        driver: any DatabaseDriver, query: DriverQuery, limits: MCPQueryLimits
    ) async throws -> ReadOnlyQueryResult {
        let limits = limits.clamped()
        return try await withThrowingTaskGroup(of: ReadOnlyQueryResult?.self) { group in
            group.addTask {
                try await drain(driver: driver, query: query, limits: limits)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(limits.timeoutSeconds))
                return nil  // timeout marker
            }
            // First finisher wins; drivers honor Task cancellation, so
            // cancelAll() also cancels the losing (or timed-out) query.
            guard let result = try await group.next() ?? nil else {
                group.cancelAll()
                throw MCPQueryTimeout(seconds: limits.timeoutSeconds)
            }
            group.cancelAll()
            return result
        }
    }

    private static func drain(
        driver: any DatabaseDriver, query: DriverQuery, limits: MCPQueryLimits
    ) async throws -> ReadOnlyQueryResult {
        let execution = try await driver.execute(
            query, pageSize: min(limits.maxRows, 500))
        var rows: [[DBValue]] = []
        var bytes = 0
        var truncated = false
        chunkLoop: for try await chunk in execution.chunks {
            for row in chunk.rows {
                let size = approximateSize(of: row.values)
                if rows.count >= limits.maxRows || bytes + size > limits.maxBytes {
                    truncated = true
                    await execution.cancel()
                    break chunkLoop
                }
                rows.append(row.values)
                bytes += size
            }
        }
        return ReadOnlyQueryResult(columns: execution.columns, rows: rows, truncated: truncated)
    }

    /// Rough serialized size, used only to enforce the byte cap.
    static func approximateSize(of values: [DBValue]) -> Int {
        values.reduce(0) { $0 + $1.displayString.utf8.count + 4 }
    }
}
