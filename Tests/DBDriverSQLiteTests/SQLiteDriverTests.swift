import DBCore
import Foundation
import GRDB
import Testing

@testable import DBDriverSQLite

/// SQLite tests need no server, so they always run.
@Suite struct SQLiteDriverTests {
    private func makeDatabase() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE people (
                    id INTEGER PRIMARY KEY, name TEXT, score REAL, avatar BLOB
                );
                CREATE VIEW active_people AS SELECT * FROM people;
                """)
            for index in 0..<1000 {
                try db.execute(
                    sql: "INSERT INTO people (name, score) VALUES (?, ?)",
                    arguments: ["person\(index)", Double(index) / 2])
            }
        }
        return path
    }

    private func makeDriver(_ path: String) throws -> SQLiteDriver {
        try SQLiteDriver(config: ResolvedConnectionConfig(filePath: path))
    }

    private func collectAll(_ execution: QueryExecution) async throws -> [ResultRow] {
        var rows: [ResultRow] = []
        for try await chunk in execution.chunks {
            rows.append(contentsOf: chunk.rows)
        }
        return rows
    }

    @Test func selectTypesAndNull() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        let execution = try await driver.execute(
            .sql("SELECT 42 AS answer, 'hi' AS greeting, 1.5 AS ratio, NULL AS missing, x'0102' AS blob"),
            pageSize: 10)
        #expect(execution.columns.map(\.name) == [
            "answer", "greeting", "ratio", "missing", "blob",
        ])
        let rows = try await collectAll(execution)
        let values = rows[0].values
        #expect(values[0] == .int(42))
        #expect(values[1] == .string("hi"))
        #expect(values[2] == .double(1.5))
        #expect(values[3] == .null)
        #expect(values[4] == .bytes(Data([1, 2])))
        await driver.disconnect()
    }

    @Test func streamsInChunks() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        let execution = try await driver.execute(
            .sql("SELECT * FROM people"), pageSize: 100)
        var chunks = 0
        var rows = 0
        for try await chunk in execution.chunks {
            chunks += 1
            rows += chunk.rows.count
            #expect(chunk.rows.count <= 100)
        }
        #expect(rows == 1000)
        #expect(chunks >= 10)
        await driver.disconnect()
    }

    @Test func cancelInterruptsLongQuery() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        // Cartesian self-joins: billions of rows, must be interrupted.
        let execution = try await driver.execute(
            .sql("SELECT a.id FROM people a, people b, people c"),
            pageSize: 100)
        let started = Date()
        var rowsSeen = 0
        do {
            for try await chunk in execution.chunks {
                rowsSeen += chunk.rows.count
                if rowsSeen >= 200 {
                    await execution.cancel()
                }
            }
        } catch let error as DBError {
            #expect(error.kind == .cancelled)
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(rowsSeen < 1_000_000_000)
        await driver.disconnect()
    }

    @Test func listsTablesViewsAndColumns() async throws {
        let path = try makeDatabase()
        let driver = try makeDriver(path)
        try await driver.connect()

        let roots = try await driver.listNamespaces(parent: nil)
        #expect(roots.count == 1)
        #expect(roots[0].name == "test.sqlite")

        let tables = try await driver.listNamespaces(parent: roots[0])
        #expect(tables.contains { $0.name == "people" && $0.kind == .table(.table) })
        #expect(tables.contains { $0.name == "active_people" && $0.kind == .table(.view) })

        let people = tables.first { $0.name == "people" }!
        let columns = try await driver.listColumns(of: people)
        #expect(columns.map(\.name) == ["id", "name", "score", "avatar"])
        #expect(columns[0].dbTypeName == "INTEGER")
        await driver.disconnect()
    }

    @Test func describesTableStructure() async throws {
        let path = try makeDatabase()
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE orders (
                    id INTEGER PRIMARY KEY,
                    customer TEXT NOT NULL,
                    status TEXT DEFAULT 'open',
                    total REAL
                );
                CREATE INDEX idx_orders_status ON orders(status, customer);
                CREATE UNIQUE INDEX idx_orders_customer ON orders(customer);
                """)
        }
        let driver = try makeDriver(path)
        try await driver.connect()

        let structure = try await driver.describeTable(
            Namespace(path: ["orders"], kind: .table(.table), isExpandable: false))

        #expect(structure.columns.map(\.name) == ["id", "customer", "status", "total"])
        let id = structure.columns[0]
        #expect(id.isPrimaryKey)
        #expect(id.dbTypeName == "INTEGER")
        let customer = structure.columns[1]
        #expect(!customer.isNullable)
        #expect(!customer.isPrimaryKey)
        let status = structure.columns[2]
        #expect(status.isNullable)
        #expect(status.defaultValue == "'open'")

        // Synthetic PRIMARY KEY entry first (rowid alias has no real index),
        // then the named indexes.
        #expect(structure.indexes.first?.isPrimary == true)
        #expect(structure.indexes.first?.columns == ["id"])
        let statusIndex = structure.indexes.first { $0.name == "idx_orders_status" }
        #expect(statusIndex?.columns == ["status", "customer"])
        #expect(statusIndex?.isUnique == false)
        let customerIndex = structure.indexes.first { $0.name == "idx_orders_customer" }
        #expect(customerIndex?.isUnique == true)
        await driver.disconnect()
    }

    @Test func describesViewWithoutIndexes() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()
        let structure = try await driver.describeTable(
            Namespace(path: ["active_people"], kind: .table(.view), isExpandable: false))
        // Views have columns but no indexes in SQLite.
        #expect(structure.columns.map(\.name) == ["id", "name", "score", "avatar"])
        #expect(structure.indexes.isEmpty)
        await driver.disconnect()
    }

    @Test func errorSurfacesMessage() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        var sawError = false
        do {
            let execution = try await driver.execute(
                .sql("SELECT * FROM does_not_exist"), pageSize: 10)
            _ = try await collectAll(execution)
        } catch let error as DBError {
            sawError = error.kind == .queryFailed
                && error.message.contains("does_not_exist")
        }
        #expect(sawError)
        await driver.disconnect()
    }

    @Test func missingFileFailsToConnect() async throws {
        let driver = try makeDriver("/nonexistent/nope.sqlite")
        await #expect(throws: DBError.self) {
            try await driver.connect()
        }
    }

    @Test func executeBatchCommitsAtomically() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        let results = try await driver.executeBatch([
            "UPDATE people SET score = -1 WHERE id <= 5",
            "DELETE FROM people WHERE id = 6",
            "INSERT INTO people (name, score) VALUES ('batch', 9.5)",
        ])
        #expect(results.count == 3)
        #expect(results[0].affectedCount == 5)
        #expect(results[1].affectedCount == 1)
        #expect(results[2].affectedCount == 1)

        let rows = try await collectAll(try await driver.execute(
            .sql("SELECT count(*) FROM people WHERE score = -1 OR name = 'batch'"),
            pageSize: 10))
        #expect(rows[0].values[0] == .int(6))
        await driver.disconnect()
    }

    @Test func executeBatchRollsBackOnFailure() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        var batchError: BatchError?
        do {
            _ = try await driver.executeBatch([
                "UPDATE people SET score = -1 WHERE id = 1",
                "INSERT INTO people (id, name) VALUES (1, 'dupe')",  // PK violation
            ])
        } catch let error as BatchError {
            batchError = error
        }
        #expect(batchError?.statementIndex == 1)
        #expect(batchError?.rolledBack == true)

        // First statement must have been rolled back too.
        let rows = try await collectAll(try await driver.execute(
            .sql("SELECT count(*) FROM people WHERE score = -1"), pageSize: 10))
        #expect(rows[0].values[0] == .int(0))
        await driver.disconnect()
    }

    @Test func executeBatchRunsDDL() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        _ = try await driver.executeBatch([
            """
            CREATE TABLE tags (
              "id" INTEGER PRIMARY KEY,
              "label" TEXT NOT NULL
            )
            """,
            #"CREATE UNIQUE INDEX "idx_tags_label" ON "tags" ("label")"#,
        ])
        let structure = try await driver.describeTable(
            Namespace(path: ["tags"], kind: .table(.table), isExpandable: false))
        #expect(structure.columns.map(\.name) == ["id", "label"])
        #expect(structure.columns[0].isPrimaryKey)
        #expect(structure.indexes.contains { $0.name == "idx_tags_label" && $0.isUnique })
        await driver.disconnect()
    }

    @Test func builderGeneratedDDLRoundTrips() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        let table = Namespace(path: ["orders"], kind: .table(.table), isExpandable: false)
        let descriptor = SQLiteDriver.descriptor
        let createTable = try DDLStatementBuilder.createTable(
            table,
            columns: [
                ColumnDefinition(name: "id", typeName: "INTEGER", isPrimaryKey: true),
                ColumnDefinition(name: "customer", typeName: "TEXT", isNullable: false),
                ColumnDefinition(name: "status", typeName: "TEXT", defaultExpression: "'open'"),
            ],
            for: descriptor)
        let createIndex = try DDLStatementBuilder.createIndex(
            named: "idx_orders_customer", on: table, columns: ["customer"],
            unique: true, for: descriptor)
        _ = try await driver.executeBatch([createTable, createIndex])

        let structure = try await driver.describeTable(table)
        #expect(structure.columns.map(\.name) == ["id", "customer", "status"])
        #expect(structure.columns[0].isPrimaryKey)
        #expect(!structure.columns[1].isNullable)
        #expect(structure.columns[2].defaultValue == "'open'")
        #expect(structure.indexes.contains {
            $0.name == "idx_orders_customer" && $0.isUnique
        })

        // Alter round-trip: add, rename, then drop a column.
        _ = try await driver.executeBatch([
            try DDLStatementBuilder.addColumn(
                ColumnDefinition(name: "total", typeName: "REAL"), to: table, for: descriptor)
        ])
        _ = try await driver.executeBatch([
            DDLStatementBuilder.renameColumn("total", to: "amount", in: table, for: descriptor)
        ])
        var altered = try await driver.describeTable(table)
        #expect(altered.columns.map(\.name).contains("amount"))

        _ = try await driver.executeBatch([
            DDLStatementBuilder.dropColumn("amount", from: table, for: descriptor)
        ])
        altered = try await driver.describeTable(table)
        #expect(!altered.columns.map(\.name).contains("amount"))

        // Drop index + drop table leave a clean slate.
        _ = try await driver.executeBatch([
            try DDLStatementBuilder.dropIndex(
                named: "idx_orders_customer", on: table, for: descriptor)
        ])
        _ = try await driver.executeBatch([
            DDLStatementBuilder.dropTable(table, for: descriptor)
        ])
        let tables = try await driver.listNamespaces(
            parent: Namespace(path: ["test.sqlite"], kind: .database, isExpandable: true))
        #expect(!tables.contains { $0.name == "orders" })
        await driver.disconnect()
    }

    @Test func dmlReportsAffectedCount() async throws {
        let driver = try makeDriver(try makeDatabase())
        try await driver.connect()

        let execution = try await driver.execute(
            .sql("UPDATE people SET score = 0 WHERE id <= 10"), pageSize: 10)
        var affected: Int?
        for try await chunk in execution.chunks where chunk.isFinal {
            affected = chunk.affectedCount
        }
        #expect(affected == 10)
        await driver.disconnect()
    }
}
