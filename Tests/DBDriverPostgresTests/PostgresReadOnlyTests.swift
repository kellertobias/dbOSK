import DBCore
import Foundation
import Testing

@testable import DBDriverPostgres

/// Verifies the engine-enforced read-only session (Layer 2 of the MCP
/// read-only design): even when the SQL-level gate is bypassed and a write
/// reaches the driver, Postgres itself rejects it.
/// Enable with: DBOSK_PG_TESTS=1 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBOSK_PG_TESTS"] == "1"))
struct PostgresReadOnlyTests {
    private func makeDriver(readOnly: Bool) throws -> PostgresDriver {
        try PostgresDriver(config: ResolvedConnectionConfig(
            host: "localhost",
            port: 54329,
            user: "dbosk",
            password: "dbosk",
            database: "dbosk_test",
            tls: .disabled,
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

        let execution = try await driver.execute(.sql("SELECT 1"), pageSize: 10)
        try await drain(execution)
    }

    @Test func readOnlySessionRejectsWritesAtTheEngine() async throws {
        let driver = try makeDriver(readOnly: true)
        try await driver.connect()
        defer { Task { await driver.disconnect() } }

        // Deliberately bypasses ReadOnlySQLGate: this must fail in Postgres.
        await #expect(throws: (any Error).self) {
            let execution = try await driver.execute(
                .sql("CREATE TABLE mcp_should_never_exist (id int)"), pageSize: 10)
            try await drain(execution)
        }
    }

    @Test func writableSessionStaysWritable() async throws {
        // Sanity check that the flag (not the test database) is what blocks
        // writes: default connections can still create and drop.
        let driver = try makeDriver(readOnly: false)
        try await driver.connect()
        defer { Task { await driver.disconnect() } }

        try await drain(try await driver.execute(
            .sql("CREATE TEMP TABLE mcp_rw_check (id int)"), pageSize: 10))
        try await drain(try await driver.execute(
            .sql("DROP TABLE mcp_rw_check"), pageSize: 10))
    }
}
