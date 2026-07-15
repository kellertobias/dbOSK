import DBCore
import Foundation
import Testing

@testable import MCPServer

@Suite struct ReadOnlyQueryRunnerTests {

    @Test func returnsAllRowsUnderCaps() async throws {
        let driver = FakeDriver(rows: (0..<5).map { [.int(Int64($0))] })
        let result = try await ReadOnlyQueryRunner.run(
            driver: driver, query: .sql("SELECT 1"), limits: MCPQueryLimits())
        #expect(result.rows.count == 5)
        #expect(!result.truncated)
    }

    @Test func rowCapTruncates() async throws {
        let driver = FakeDriver(rows: (0..<50).map { [.int(Int64($0))] })
        let result = try await ReadOnlyQueryRunner.run(
            driver: driver, query: .sql("SELECT 1"),
            limits: MCPQueryLimits(maxRows: 10))
        #expect(result.rows.count == 10)
        #expect(result.truncated)
    }

    @Test func byteCapTruncates() async throws {
        let bigCell = String(repeating: "x", count: 2000)
        let driver = FakeDriver(rows: (0..<20).map { _ in [.string(bigCell)] })
        let result = try await ReadOnlyQueryRunner.run(
            driver: driver, query: .sql("SELECT 1"),
            limits: MCPQueryLimits(maxBytes: 5000))
        #expect(result.truncated)
        #expect(result.rows.count < 20)
        #expect(!result.rows.isEmpty)
    }

    @Test func timeoutCancelsSlowQueries() async throws {
        let driver = FakeDriver(rows: [[.int(1)]], delay: .seconds(30))
        await #expect(throws: MCPQueryTimeout.self) {
            _ = try await ReadOnlyQueryRunner.run(
                driver: driver, query: .sql("SELECT pg_sleep(30)"),
                limits: MCPQueryLimits(timeoutSeconds: 1))
        }
    }

    @Test func limitsClampToHardCaps() {
        let clamped = MCPQueryLimits(
            maxRows: 1_000_000, maxBytes: 500_000_000, timeoutSeconds: 100_000
        ).clamped()
        #expect(clamped.maxRows == MCPQueryLimits.hardMaxRows)
        #expect(clamped.maxBytes == MCPQueryLimits.hardMaxBytes)
        #expect(clamped.timeoutSeconds == MCPQueryLimits.hardTimeoutSeconds)
    }
}
