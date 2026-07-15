import Foundation

/// Per-profile MCP exposure: nothing is reachable over MCP until the user
/// opts the profile in, and even then queries may be restricted to an
/// explicit namespace allowlist.
public struct MCPAccessConfig: Codable, Sendable, Equatable {
    /// What the MCP server may touch on this connection.
    public enum Scope: Codable, Sendable, Equatable {
        /// Every table/collection the connection can see.
        case allTables
        /// Only namespaces on the list (a path may be a whole database or
        /// schema, allowing everything beneath it).
        case allowlist([[String]])
    }

    /// Per-profile opt-in; false keeps the connection invisible to MCP.
    public var enabled: Bool
    public var scope: Scope

    public init(enabled: Bool = false, scope: Scope = .allTables) {
        self.enabled = enabled
        self.scope = scope
    }

    /// Whether a namespace path (database/schema/table) is inside the scope.
    /// An allowlist entry admits itself and everything beneath it; parents of
    /// an allowed entry are also visible so clients can walk down to it.
    /// Comparison is case-insensitive: Postgres folds unquoted identifiers,
    /// MySQL table-name case sensitivity is platform-defined, and a
    /// case-flipped bypass must not be possible either way.
    public func allows(path: [String]) -> Bool {
        guard enabled else { return false }
        switch scope {
        case .allTables:
            return true
        case .allowlist(let entries):
            let lowered = path.map { $0.lowercased() }
            return entries.contains { entry in
                let entryLowered = entry.map { $0.lowercased() }
                return lowered.starts(with: entryLowered)
                    || entryLowered.starts(with: lowered)
            }
        }
    }

    /// Whether a query may *read* the namespace: unlike `allows(path:)`,
    /// being a parent of an allowlist entry is not enough — allowing
    /// `["db", "schema", "users"]` must not admit a query on `["db"]`.
    public func allowsReading(path: [String]) -> Bool {
        guard enabled else { return false }
        switch scope {
        case .allTables:
            return true
        case .allowlist(let entries):
            let lowered = path.map { $0.lowercased() }
            return entries.contains { entry in
                lowered.starts(with: entry.map { $0.lowercased() })
            }
        }
    }
}

/// Loads/saves the MCP access map (profile id → config) as one JSON file at
/// `~/Library/Application Support/dbosk/mcp-access.json`.
public struct MCPAccessStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("dbosk/mcp-access.json")
        }
    }

    public func load() -> [UUID: MCPAccessConfig] {
        guard let data = try? Data(contentsOf: fileURL),
            let map = try? JSONDecoder().decode([UUID: MCPAccessConfig].self, from: data)
        else { return [:] }
        return map
    }

    public func save(_ map: [UUID: MCPAccessConfig]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(map).write(to: fileURL, options: .atomic)
    }
}
