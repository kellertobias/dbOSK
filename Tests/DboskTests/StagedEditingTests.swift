import DBCore
import DBDriverSQLite
import Foundation
import GRDB
import Testing

@testable import Dbosk

@Suite @MainActor struct PendingChangeSetTests {
    @Test func editRevertsWhenTextMatchesOriginal() {
        let pending = PendingChangeSet()
        pending.setEdit(row: 0, column: 1, text: "new", originalText: "old")
        #expect(pending.cellEdits == [0: [1: "new"]])
        // Typing the original text back removes the staged edit entirely.
        pending.setEdit(row: 0, column: 1, text: "old", originalText: "old")
        #expect(pending.isEmpty)
    }

    @Test func nullSentinelIsAStagedEdit() {
        let pending = PendingChangeSet()
        pending.setEdit(row: 2, column: 0, text: nil, originalText: "x")
        #expect(pending.cellEdits[2]?[0] == String?.none)
        #expect(!pending.isEmpty)
    }

    @Test func summaryCountsKinds() {
        let pending = PendingChangeSet()
        pending.setEdit(row: 0, column: 0, text: "a", originalText: nil)
        pending.setEdit(row: 1, column: 0, text: "b", originalText: nil)
        pending.markDeleted([5, 6])
        pending.addInsertedRow()
        #expect(pending.summary == "2 updates, 1 insert, 2 deletes")
    }

    @Test func deleteTogglesAndDiscardClears() {
        let pending = PendingChangeSet()
        pending.markDeleted([3])
        pending.unmarkDeleted(3)
        #expect(pending.isEmpty)

        let id = pending.addInsertedRow()
        pending.setInsertedValue(id: id, column: 0, text: "x")
        pending.markDeleted([1])
        pending.discardAll()
        #expect(pending.isEmpty)
        #expect(pending.insertedRows.isEmpty)
    }
}

@Suite @MainActor struct TableBrowserEditingTests {
    private func makeDatabase() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE people (
                    id INTEGER PRIMARY KEY, name TEXT, score REAL
                );
                CREATE TABLE nokey (name TEXT);
                """)
            for index in 1...5 {
                try db.execute(
                    sql: "INSERT INTO people (id, name, score) VALUES (?, ?, ?)",
                    arguments: [index, "person\(index)", Double(index)])
            }
        }
        return path
    }

    private func makeBrowser(_ path: String) async throws -> TableBrowser {
        let driver = try SQLiteDriver(config: ResolvedConnectionConfig(filePath: path))
        try await driver.connect()
        return TableBrowser(driver: driver)
    }

    /// Polls until the browser has loaded data and structure.
    private func loadTable(_ browser: TableBrowser, _ name: String) async throws {
        browser.select(Namespace(path: [name], kind: .table(.table), isExpandable: false))
        for _ in 0..<2000 {
            if case .done = browser.resultTab.runState,
               browser.structure != nil || browser.structureError != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out loading \(name)")
    }

    @Test func editingGatedOnPrimaryKey() async throws {
        let browser = try await makeBrowser(try makeDatabase())
        try await loadTable(browser, "people")
        #expect(browser.editingDisabledReason == nil)

        try await loadTable(browser, "nokey")
        #expect(browser.editingDisabledReason == "Table has no primary key")
    }

    @Test func buildsStatementsInDeleteUpdateInsertOrder() async throws {
        let browser = try await makeBrowser(try makeDatabase())
        try await loadTable(browser, "people")

        // Row ids are 0-based result indexes; people ids are 1-based.
        browser.pending.markDeleted([4])
        browser.pending.setEdit(row: 0, column: 1, text: "renamed", originalText: "person1")
        browser.pending.setEdit(row: 0, column: 2, text: nil, originalText: "1.0")
        let inserted = browser.pending.addInsertedRow()
        browser.pending.setInsertedValue(id: inserted, column: 1, text: "new person")

        let statements = try browser.buildApplyStatements()
        #expect(statements == [
            #"DELETE FROM "people" WHERE "id" = 5"#,
            #"UPDATE "people" SET "name" = 'renamed', "score" = NULL WHERE "id" = 1"#,
            #"INSERT INTO "people" ("name") VALUES ('new person')"#,
        ])
    }

    @Test func deletedRowSkipsItsEdits() async throws {
        let browser = try await makeBrowser(try makeDatabase())
        try await loadTable(browser, "people")

        browser.pending.setEdit(row: 2, column: 1, text: "x", originalText: nil)
        browser.pending.markDeleted([2])
        let statements = try browser.buildApplyStatements()
        #expect(statements == [#"DELETE FROM "people" WHERE "id" = 3"#])
    }

    @Test func typeErrorsNameTheColumn() async throws {
        let browser = try await makeBrowser(try makeDatabase())
        try await loadTable(browser, "people")

        // score is REAL; SQLite result columns report "any", so the declared
        // type from the structure must drive parsing.
        browser.pending.setEdit(row: 0, column: 2, text: "not a number", originalText: nil)
        var message: String?
        do {
            _ = try browser.buildApplyStatements()
        } catch let error as DBError {
            message = error.message
        }
        #expect(message == #"Column "score": Not a valid number: not a number"#)
    }

    @Test func applyCommitsAndReloads() async throws {
        let browser = try await makeBrowser(try makeDatabase())
        try await loadTable(browser, "people")

        browser.pending.setEdit(row: 0, column: 1, text: "renamed", originalText: "person1")
        browser.pending.markDeleted([4])
        let inserted = browser.pending.addInsertedRow()
        browser.pending.setInsertedValue(id: inserted, column: 0, text: "99")
        browser.pending.setInsertedValue(id: inserted, column: 1, text: "ninety-nine")

        browser.apply(statements: try browser.buildApplyStatements())
        for _ in 0..<2000 where !(browser.applyState == .idle && browser.pending.isEmpty) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(browser.applyState == .idle)
        #expect(browser.pending.isEmpty)

        for _ in 0..<2000 {
            if case .done = browser.resultTab.runState { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let names = browser.resultTab.rows.map { $0.values[1] }
        #expect(names.contains(.string("renamed")))
        #expect(names.contains(.string("ninety-nine")))
        #expect(!names.contains(.string("person5")))
        #expect(!names.contains(.string("person1")))
    }

    @Test func failedApplyKeepsPendingSet() async throws {
        let browser = try await makeBrowser(try makeDatabase())
        try await loadTable(browser, "people")

        browser.pending.setEdit(row: 0, column: 1, text: "kept", originalText: nil)
        let inserted = browser.pending.addInsertedRow()
        browser.pending.setInsertedValue(id: inserted, column: 0, text: "1")  // PK collision
        browser.pending.setInsertedValue(id: inserted, column: 1, text: "dupe")

        browser.apply(statements: try browser.buildApplyStatements())
        for _ in 0..<2000 where browser.applyState == .applying || browser.applyState == .idle {
            try await Task.sleep(for: .milliseconds(5))
            if case .failed = browser.applyState { break }
        }
        guard case .failed = browser.applyState else {
            Issue.record("Expected apply to fail, got \(browser.applyState)")
            return
        }
        // Transaction rolled back; staged edits stay for fixing.
        #expect(!browser.pending.isEmpty)
        #expect(browser.pending.cellEdits[0]?[1] == "kept")

        // The update must not have been half-applied.
        let check = try browser.buildApplyStatements()
        #expect(check.count == 2)
    }

    @Test func navigationGuardParksActionUntilConfirmed() async throws {
        let browser = try await makeBrowser(try makeDatabase())
        try await loadTable(browser, "people")

        browser.pending.setEdit(row: 0, column: 1, text: "x", originalText: nil)
        var ran = false
        browser.requestNavigation { ran = true }
        #expect(!ran)
        #expect(browser.pendingNavigation != nil)

        browser.confirmPendingNavigation()
        #expect(ran)
        #expect(browser.pending.isEmpty)

        // Without pending edits the action runs immediately.
        var immediate = false
        browser.requestNavigation { immediate = true }
        #expect(immediate)
    }
}
