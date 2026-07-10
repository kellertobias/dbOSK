import DBCore
import DBDriverSQLite
import Foundation
import GRDB
import Testing

@testable import Dbosk

/// Covers the grid ↔ PendingChangeSet bridge: display-row overlay, per-cell
/// display state, commit semantics (empty vs NULL), and delete toggling.
@Suite @MainActor struct TableBrowserEditingUITests {
    private func makeDatabase() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-editing-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE people (
                    id INTEGER PRIMARY KEY, name TEXT, score REAL
                );
                """)
            try db.execute(
                sql: "INSERT INTO people (id, name, score) VALUES (1, 'alice', 1.5)")
            try db.execute(
                sql: "INSERT INTO people (id, name, score) VALUES (2, NULL, NULL)")
        }
        return path
    }

    private func makeLoadedBrowser() async throws -> TableBrowser {
        let driver = try SQLiteDriver(
            config: ResolvedConnectionConfig(filePath: try makeDatabase()))
        try await driver.connect()
        let browser = TableBrowser(driver: driver)
        browser.select(Namespace(path: ["people"], kind: .table(.table), isExpandable: false))
        for _ in 0..<2000 {
            if case .done = browser.resultTab.runState, browser.structure != nil {
                return browser
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out loading people")
        return browser
    }

    // MARK: Display overlay

    @Test func displayRowsAppendInsertedRows() async throws {
        let browser = try await makeLoadedBrowser()
        #expect(browser.displayRows.count == 2)

        let inserted = browser.pending.addInsertedRow()
        browser.pending.setInsertedValue(id: inserted, column: 1, text: "carol")
        let rows = browser.displayRows
        #expect(rows.count == 3)
        #expect(rows[2].id == 2)
        #expect(rows[2].values == [.null, .string("carol"), .null])
    }

    @Test func cellDisplayStates() async throws {
        let browser = try await makeLoadedBrowser()

        // Clean cell: original text, no highlight.
        #expect(browser.cellDisplay(row: 0, column: 1)
            == .init(text: "alice"))
        // NULL original: empty text, NULL placeholder, null styling.
        #expect(browser.cellDisplay(row: 1, column: 1)
            == .init(text: "", placeholder: "NULL", isNullStyle: true))

        // Staged edit: bold accent, staged text.
        browser.commitCellText(row: 0, column: 1, text: "renamed")
        #expect(browser.cellDisplay(row: 0, column: 1)
            == .init(text: "renamed", highlight: .edited))

        // Staged NULL: NULL placeholder with edited highlight.
        browser.stageNull(row: 0, column: 2)
        #expect(browser.cellDisplay(row: 0, column: 2)
            == .init(text: "", placeholder: "NULL", isNullStyle: true, highlight: .edited))

        // Deleted row shows original values with deleted highlight (edits and all).
        browser.deleteDisplayRows(IndexSet(integer: 0))
        #expect(browser.cellDisplay(row: 0, column: 1)
            == .init(text: "alice", highlight: .deleted))

        // Inserted row: set / staged-NULL / unset cells.
        let inserted = browser.pending.addInsertedRow()
        browser.pending.setInsertedValue(id: inserted, column: 1, text: "carol")
        browser.pending.setInsertedValue(id: inserted, column: 2, text: nil)
        let insertedRow = browser.baseRowCount
        #expect(browser.cellDisplay(row: insertedRow, column: 1)
            == .init(text: "carol", highlight: .inserted))
        #expect(browser.cellDisplay(row: insertedRow, column: 2)
            == .init(text: "", placeholder: "NULL", isNullStyle: true, highlight: .inserted))
        #expect(browser.cellDisplay(row: insertedRow, column: 0)
            == .init(text: "", placeholder: "default", isNullStyle: true, highlight: .inserted))
    }

    // MARK: Commit semantics

    @Test func retypingOriginalRevertsTheEdit() async throws {
        let browser = try await makeLoadedBrowser()
        browser.commitCellText(row: 0, column: 1, text: "renamed")
        #expect(!browser.pending.isEmpty)
        browser.commitCellText(row: 0, column: 1, text: "alice")
        #expect(browser.pending.isEmpty)
    }

    @Test func emptyTextIsNotNull() async throws {
        let browser = try await makeLoadedBrowser()

        // Empty over a NULL original: no edit staged (NULL needs the menu).
        browser.commitCellText(row: 1, column: 1, text: "")
        #expect(browser.pending.isEmpty)

        // Empty over a non-null original: stages an empty string.
        browser.commitCellText(row: 0, column: 1, text: "")
        #expect(browser.pending.cellEdits[0]?[1] == "")

        // Committing empty text after staging NULL on a null original reverts.
        browser.commitCellText(row: 1, column: 1, text: "x")
        browser.commitCellText(row: 1, column: 1, text: "")
        #expect(browser.pending.cellEdits[1] == nil)
    }

    @Test func stageNullOnNullOriginalStaysClean() async throws {
        let browser = try await makeLoadedBrowser()
        browser.stageNull(row: 1, column: 1)
        #expect(browser.pending.isEmpty)
    }

    @Test func insertedRowCellCommits() async throws {
        let browser = try await makeLoadedBrowser()
        let insertedID = browser.pending.addInsertedRow()
        let row = browser.baseRowCount

        browser.commitCellText(row: row, column: 1, text: "carol")
        #expect(browser.pending.insertedRows[0].cells[1] == "carol")

        // Empty text over a set cell reverts it to unset (DB default).
        browser.commitCellText(row: row, column: 1, text: "")
        #expect(browser.pending.insertedRows[0].cells[1] == nil)

        // Staged NULL survives an empty-text commit.
        browser.stageNull(row: row, column: 2)
        browser.commitCellText(row: row, column: 2, text: "")
        #expect(browser.pending.insertedRows[0].cells[2] == String?.none)

        browser.revertCell(row: row, column: 2)
        #expect(browser.pending.insertedRows[0].cells[2] == nil)
        _ = insertedID
    }

    // MARK: Deletes

    @Test func deleteTogglesAndRemovesInsertedRows() async throws {
        let browser = try await makeLoadedBrowser()

        browser.deleteDisplayRows(IndexSet(integer: 0))
        #expect(browser.pending.deletedRowIDs == [0])
        // Deleting again toggles the mark off.
        browser.deleteDisplayRows(IndexSet(integer: 0))
        #expect(browser.pending.deletedRowIDs.isEmpty)

        _ = browser.pending.addInsertedRow()
        browser.deleteDisplayRows(IndexSet(integer: browser.baseRowCount))
        #expect(browser.pending.insertedRows.isEmpty)
    }

    // MARK: Config gating

    @Test func editingConfigTracksEditability() async throws {
        let browser = try await makeLoadedBrowser()
        #expect(browser.editingConfig != nil)

        // A fresh browser without loaded data is not editable.
        let driver = try SQLiteDriver(
            config: ResolvedConnectionConfig(filePath: try makeDatabase()))
        try await driver.connect()
        let fresh = TableBrowser(driver: driver)
        #expect(fresh.editingConfig == nil)
    }

    // MARK: Schema-change refresh

    @Test func refreshAfterSchemaChangeResetsEditingState() async throws {
        let browser = try await makeLoadedBrowser()
        browser.commitCellText(row: 0, column: 1, text: "renamed")
        browser.selectedColumns = ["name"]

        try await browser.runDDL(#"ALTER TABLE "people" ADD COLUMN "age" INTEGER"#)
        browser.refreshAfterSchemaChange()
        for _ in 0..<2000 {
            if !browser.isLoadingColumns, !browser.isLoadingStructure,
               case .done = browser.resultTab.runState { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(browser.pending.isEmpty)
        #expect(browser.selectedColumns.isEmpty)
        #expect(browser.availableColumns.map(\.name) == ["id", "name", "score", "age"])
        #expect(browser.structure?.columns.map(\.name) == ["id", "name", "score", "age"])
    }
}
