import DBCore
import Foundation
import Observation

/// Staged, not-yet-applied table edits. Values are editor text keyed by result
/// column index; `nil` text is the explicit NULL sentinel. Original rows are
/// never mutated — the grid overlays these on top of `QueryTab.rows`.
@Observable
@MainActor
final class PendingChangeSet {
    struct InsertedRow: Identifiable {
        let id = UUID()
        /// Only explicitly set cells; unset columns fall to their DB default.
        var cells: [Int: String?] = [:]
    }

    /// resultRow.id → (columnIndex → text, nil = NULL).
    private(set) var cellEdits: [Int: [Int: String?]] = [:]
    private(set) var deletedRowIDs: Set<Int> = []
    private(set) var insertedRows: [InsertedRow] = []
    /// Bumped on every change so AppKit views can redraw highlights cheaply.
    private(set) var version = 0

    var isEmpty: Bool {
        cellEdits.isEmpty && deletedRowIDs.isEmpty && insertedRows.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if !cellEdits.isEmpty {
            parts.append("\(cellEdits.count) update\(cellEdits.count == 1 ? "" : "s")")
        }
        if !insertedRows.isEmpty {
            parts.append("\(insertedRows.count) insert\(insertedRows.count == 1 ? "" : "s")")
        }
        if !deletedRowIDs.isEmpty {
            parts.append("\(deletedRowIDs.count) delete\(deletedRowIDs.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Cell edits

    /// Outer nil = no staged edit; inner nil = staged NULL.
    func editedText(row: Int, column: Int) -> String?? {
        guard let rowEdits = cellEdits[row] else { return nil }
        return rowEdits[column]
    }

    /// Stages an edit; passing the row's original display text reverts it.
    func setEdit(row: Int, column: Int, text: String?, originalText: String?) {
        if text == originalText {
            revertEdit(row: row, column: column)
            return
        }
        cellEdits[row, default: [:]][column] = text
        version += 1
    }

    func revertEdit(row: Int, column: Int) {
        guard cellEdits[row]?.removeValue(forKey: column) != nil else { return }
        if cellEdits[row]?.isEmpty == true { cellEdits[row] = nil }
        version += 1
    }

    // MARK: Row deletes

    func markDeleted(_ rowIDs: some Sequence<Int>) {
        deletedRowIDs.formUnion(rowIDs)
        version += 1
    }

    func unmarkDeleted(_ rowID: Int) {
        guard deletedRowIDs.remove(rowID) != nil else { return }
        version += 1
    }

    // MARK: Row inserts

    @discardableResult
    func addInsertedRow() -> InsertedRow.ID {
        let row = InsertedRow()
        insertedRows.append(row)
        version += 1
        return row.id
    }

    func removeInsertedRow(id: InsertedRow.ID) {
        guard let index = insertedRows.firstIndex(where: { $0.id == id }) else { return }
        insertedRows.remove(at: index)
        version += 1
    }

    func setInsertedValue(id: InsertedRow.ID, column: Int, text: String?) {
        guard let index = insertedRows.firstIndex(where: { $0.id == id }) else { return }
        insertedRows[index].cells[column] = text
        version += 1
    }

    /// Unsets a cell of a staged insert so the column falls to its DB default.
    func clearInsertedValue(id: InsertedRow.ID, column: Int) {
        guard let index = insertedRows.firstIndex(where: { $0.id == id }),
              insertedRows[index].cells.removeValue(forKey: column) != nil
        else { return }
        version += 1
    }

    func discardAll() {
        guard !isEmpty else { return }
        cellEdits = [:]
        deletedRowIDs = []
        insertedRows = []
        version += 1
    }
}
