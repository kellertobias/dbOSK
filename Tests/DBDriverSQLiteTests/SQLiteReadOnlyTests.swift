import DBCore
import Foundation
import GRDB
import Testing

@testable import DBDriverSQLite

/// Verifies the engine-enforced read-only open (Layer 2 of the MCP read-only
/// design): SQLite rejects writes on a `readOnly` connection. Needs no
/// server, so it always runs.
@Suite struct SQLiteReadOnlyTests {
    private func makeDatabase() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-sqlite-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)")
            try db.execute(sql: "INSERT INTO people (name) VALUES ('a'), ('b')")
        }
        return path
    }

    private func makeDriver(_ path: String, readOnly: Bool) throws -> SQLiteDriver {
        try SQLiteDriver(config: ResolvedConnectionConfig(
            filePath: path, readOnly: readOnly))
    }

    private func drain(_ execution: QueryExecution) async throws -> Int {
        var count = 0
        for try await chunk in execution.chunks { count += chunk.rows.count }
        return count
    }

    @Test func readOnlyConnectionAllowsSelects() async throws {
        let driver = try makeDriver(try makeDatabase(), readOnly: true)
        try await driver.connect()
        defer { Task { await driver.disconnect() } }

        let execution = try await driver.execute(
            .sql("SELECT * FROM people"), pageSize: 10)
        #expect(try await drain(execution) == 2)
    }

    @Test func readOnlyConnectionRejectsWritesAtTheEngine() async throws {
        let driver = try makeDriver(try makeDatabase(), readOnly: true)
        try await driver.connect()
        defer { Task { await driver.disconnect() } }

        // Deliberately bypasses ReadOnlySQLGate: SQLite itself must refuse.
        await #expect(throws: (any Error).self) {
            let execution = try await driver.execute(
                .sql("INSERT INTO people (name) VALUES ('nope')"), pageSize: 10)
            _ = try await drain(execution)
        }
    }
}
