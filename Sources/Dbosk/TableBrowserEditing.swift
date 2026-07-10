import DBCore
import Foundation

/// Bridges `TableBrowser`'s staged edits to the results grid: combined display
/// rows (base + inserted), per-cell display state, and commit handlers.
/// Display row indexes 0..<baseRowCount are result rows; the rest are staged
/// inserts in order.
extension TableBrowser {
    var baseRowCount: Int { resultTab.rows.count }

    /// Result rows plus placeholder rows for staged inserts.
    var displayRows: [ResultRow] {
        let base = resultTab.rows
        guard !pending.insertedRows.isEmpty else { return base }
        let width = resultTab.columns.count
        let extra = pending.insertedRows.enumerated().map { offset, inserted in
            ResultRow(
                id: base.count + offset,
                values: (0..<width).map { column in
                    if case .some(.some(let text)) = inserted.cells[column] {
                        return .string(text)
                    }
                    return .null
                })
        }
        return base + extra
    }

    /// Grid reload key: result changes and staged changes both only increment.
    var displayVersion: Int {
        resultTab.resultVersion &+ pending.version
    }

    func cellDisplay(row: Int, column: Int) -> ResultsTableView.CellDisplay {
        if row >= baseRowCount {
            guard let inserted = pending.insertedRows[safe: row - baseRowCount] else {
                return .init(text: "")
            }
            switch inserted.cells[column] {
            case .some(.some(let text)):
                return .init(text: text, highlight: .inserted)
            case .some(.none):
                return .init(text: "", placeholder: "NULL", isNullStyle: true, highlight: .inserted)
            case .none:
                return .init(text: "", placeholder: "default", isNullStyle: true, highlight: .inserted)
            }
        }
        guard let resultRow = resultTab.rows[safe: row] else { return .init(text: "") }
        let original = resultRow.values[safe: column] ?? .null

        func originalDisplay(_ highlight: ResultsTableView.CellDisplay.Highlight) -> ResultsTableView.CellDisplay {
            .init(
                text: original.isNull ? "" : original.displayString,
                placeholder: original.isNull ? "NULL" : "",
                isNullStyle: original.isNull,
                highlight: highlight)
        }

        if pending.deletedRowIDs.contains(resultRow.id) {
            return originalDisplay(.deleted)
        }
        if let staged = pending.editedText(row: resultRow.id, column: column) {
            if let text = staged {
                return .init(text: text, highlight: .edited)
            }
            return .init(text: "", placeholder: "NULL", isNullStyle: true, highlight: .edited)
        }
        return originalDisplay(.none)
    }

    /// Commit typed text from the grid. Empty text over a NULL/unset cell is
    /// not an edit — NULL is only staged explicitly via Set to NULL.
    func commitCellText(row: Int, column: Int, text: String) {
        if row >= baseRowCount {
            guard let inserted = pending.insertedRows[safe: row - baseRowCount] else { return }
            if text.isEmpty {
                switch inserted.cells[column] {
                case .some(.some): pending.clearInsertedValue(id: inserted.id, column: column)
                default: break  // unset stays unset, staged NULL stays NULL
                }
            } else {
                pending.setInsertedValue(id: inserted.id, column: column, text: text)
            }
            return
        }
        guard let resultRow = resultTab.rows[safe: row] else { return }
        let original = resultRow.values[safe: column] ?? .null
        if original.isNull {
            if text.isEmpty {
                pending.revertEdit(row: resultRow.id, column: column)
            } else {
                pending.setEdit(row: resultRow.id, column: column, text: text, originalText: nil)
            }
            return
        }
        pending.setEdit(
            row: resultRow.id, column: column,
            text: text, originalText: original.displayString)
    }

    func stageNull(row: Int, column: Int) {
        if row >= baseRowCount {
            guard let inserted = pending.insertedRows[safe: row - baseRowCount] else { return }
            pending.setInsertedValue(id: inserted.id, column: column, text: nil)
            return
        }
        guard let resultRow = resultTab.rows[safe: row] else { return }
        let original = resultRow.values[safe: column] ?? .null
        // Original NULL: setEdit(nil, originalText: nil) reverts — already NULL.
        pending.setEdit(
            row: resultRow.id, column: column,
            text: nil, originalText: original.isNull ? nil : original.displayString)
    }

    func revertCell(row: Int, column: Int) {
        if row >= baseRowCount {
            guard let inserted = pending.insertedRows[safe: row - baseRowCount] else { return }
            pending.clearInsertedValue(id: inserted.id, column: column)
            return
        }
        guard let resultRow = resultTab.rows[safe: row] else { return }
        pending.revertEdit(row: resultRow.id, column: column)
    }

    /// Delete toggles: deleting an already-marked base row unmarks it;
    /// deleting a staged insert removes it.
    func deleteDisplayRows(_ indexes: IndexSet) {
        for index in indexes.sorted(by: >) {
            if index >= baseRowCount {
                if let inserted = pending.insertedRows[safe: index - baseRowCount] {
                    pending.removeInsertedRow(id: inserted.id)
                }
            } else if let resultRow = resultTab.rows[safe: index] {
                if pending.deletedRowIDs.contains(resultRow.id) {
                    pending.unmarkDeleted(resultRow.id)
                } else {
                    pending.markDeleted([resultRow.id])
                }
            }
        }
    }

    var editingConfig: ResultsTableView.EditingConfig? {
        guard isEditable else { return nil }
        return ResultsTableView.EditingConfig(
            cellDisplay: { [weak self] row, column in
                self?.cellDisplay(row: row, column: column) ?? .init(text: "")
            },
            onEdit: { [weak self] row, column, text in
                self?.commitCellText(row: row, column: column, text: text)
            },
            onSetNull: { [weak self] row, column in
                self?.stageNull(row: row, column: column)
            },
            onRevertCell: { [weak self] row, column in
                self?.revertCell(row: row, column: column)
            },
            onInsertRow: { [weak self] in
                self?.pending.addInsertedRow()
            },
            onDeleteRows: { [weak self] indexes in
                self?.deleteDisplayRows(indexes)
            },
            onSelectionChanged: { [weak self] indexes in
                self?.selectedDisplayRows = indexes
            })
    }
}
