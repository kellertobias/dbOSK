import DBCore
import Foundation
import Testing

@testable import DBDriverMySQL

/// Verifies the engine-enforced read-only session (Layer 2 of the MCP
/// read-only design) on MySQL.
/// Enable with: DBOSK_MYSQL_TESTS=1 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBOSK_MYSQL_TESTS"] == "1"))
struct MySQLReadOnlyTests {
    private func makeDriver(readOnly: Bool) throws -> MySQLDriver {
        try MySQLDriver(config: ResolvedConnectionConfig(
            host: "127.0.0.1",
            port: 33069,
            user: "root",
            password: "dbosk",
            database: "dbosk_test",
            tls: .preferred,
            readOnly: readOnly
        ))
    }

    private func drain(_ execution: QueryExecution) async throws {
        for try await _ in execution.chunks {}
    }

    @Test func readOnlySessionAllowsSelects() async throws {
        let driver = try makeDriver(readOnly: true)
        try await driver.connect()
        defer { Task { await driver.disconnect() } }
        try await drain(try await driver.execute(.sql("SELECT 1"), pageSize: 10))
    }

    @Test func readOnlySessionRejectsWritesAtTheEngine() async throws {
        let driver = try makeDriver(readOnly: true)
        try await driver.connect()
        defer { Task { await driver.disconnect() } }

        // Deliberately bypasses ReadOnlySQLGate: MySQL itself must refuse.
        await #expect(throws: (any Error).self) {
            let execution = try await driver.execute(
                .sql("CREATE TABLE mcp_should_never_exist (id int)"), pageSize: 10)
            try await drain(execution)
        }
    }
}
