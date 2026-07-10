import AppKit
import DBCore
import SwiftUI

/// View-based NSTableView for large result sets. Reloads when `version` changes;
/// rows are looked up lazily so appending while streaming stays cheap.
/// With an `EditingConfig` (Table mode only) cells become editable text fields
/// and staged changes are tinted; without one it behaves exactly as before.
struct ResultsTableView: NSViewRepresentable {
    let columns: [ColumnMeta]
    let rows: [ResultRow]
    let version: Int
    var editing: EditingConfig?

    /// How one cell should render under staged editing.
    struct CellDisplay: Equatable {
        enum Highlight { case none, edited, deleted, inserted }
        var text: String
        /// Shown when `text` is empty: "NULL" or "default" for inserted rows.
        var placeholder: String = ""
        var isNullStyle = false
        var highlight: Highlight = .none
    }

    struct EditingConfig {
        var cellDisplay: (Int, Int) -> CellDisplay
        var onEdit: (Int, Int, String) -> Void
        var onSetNull: (Int, Int) -> Void
        var onRevertCell: (Int, Int) -> Void
        var onInsertRow: () -> Void
        var onDeleteRows: (IndexSet) -> Void
        var onSelectionChanged: (IndexSet) -> Void
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 20
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Copy Cell", action: #selector(Coordinator.copyCell(_:)),
            keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Copy Row", action: #selector(Coordinator.copyRowTSV(_:)),
            keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Copy Row as JSON", action: #selector(Coordinator.copyRowJSON(_:)),
            keyEquivalent: ""))
        let editingItems = [
            NSMenuItem.separator(),
            NSMenuItem(
                title: "Set to NULL", action: #selector(Coordinator.setCellNull(_:)),
                keyEquivalent: ""),
            NSMenuItem(
                title: "Revert Cell", action: #selector(Coordinator.revertCell(_:)),
                keyEquivalent: ""),
            NSMenuItem.separator(),
            NSMenuItem(
                title: "Insert Row", action: #selector(Coordinator.insertRow(_:)),
                keyEquivalent: ""),
            NSMenuItem(
                title: "Delete Row(s)", action: #selector(Coordinator.deleteRows(_:)),
                keyEquivalent: ""),
        ]
        for item in editingItems {
            item.tag = Coordinator.editingItemTag
            menu.addItem(item)
        }
        for item in menu.items { item.target = context.coordinator }
        menu.delegate = context.coordinator
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        // Closures capture fresh model state; refresh them on every update.
        coordinator.editing = editing
        guard coordinator.version != version else { return }
        let columnsChanged = coordinator.columns != columns
        let previousRowCount = coordinator.rows.count
        coordinator.columns = columns
        coordinator.rows = rows
        coordinator.version = version

        guard let tableView = coordinator.tableView else { return }
        if columnsChanged {
            coordinator.rebuildColumns(in: tableView)
            tableView.reloadData()
        } else if rows.count > previousRowCount, previousRowCount > 0,
                  editing == nil {
            tableView.insertRows(
                at: IndexSet(integersIn: previousRowCount..<rows.count),
                withAnimation: [])
        } else {
            tableView.reloadData()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
        NSTextFieldDelegate, NSMenuDelegate
    {
        static let editingItemTag = 1

        var columns: [ColumnMeta] = []
        var rows: [ResultRow] = []
        var version = -1
        var editing: EditingConfig?
        weak var tableView: NSTableView?

        func rebuildColumns(in tableView: NSTableView) {
            for column in tableView.tableColumns.reversed() {
                tableView.removeTableColumn(column)
            }
            for (index, meta) in columns.enumerated() {
                let column = NSTableColumn(
                    identifier: NSUserInterfaceItemIdentifier("col\(index)"))
                column.title = meta.name
                column.width = 140
                column.minWidth = 40
                tableView.addTableColumn(column)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            editing?.onSelectionChanged(tableView.selectedRowIndexes)
        }

        // MARK: Copy actions (context menu)

        @objc func copyCell(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0,
                  tableView.clickedColumn >= 0,
                  tableView.clickedRow < rows.count
            else { return }
            let values = rows[tableView.clickedRow].values
            guard tableView.clickedColumn < values.count else { return }
            setPasteboard(values[tableView.clickedColumn].displayString)
        }

        @objc func copyRowTSV(_ sender: Any?) {
            guard let row = clickedRowValues() else { return }
            setPasteboard(row.map(\.displayString).joined(separator: "\t"))
        }

        @objc func copyRowJSON(_ sender: Any?) {
            guard let row = clickedRowValues() else { return }
            var object: [String: DBValue] = [:]
            for (index, column) in columns.enumerated() where index < row.count {
                object[column.name] = row[index]
            }
            setPasteboard(DBValue.document(object).jsonString(prettyPrinted: true))
        }

        private func clickedRowValues() -> [DBValue]? {
            guard let tableView, tableView.clickedRow >= 0,
                  tableView.clickedRow < rows.count
            else { return nil }
            return rows[tableView.clickedRow].values
        }

        private func setPasteboard(_ string: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }

        // MARK: Editing actions (context menu)

        func menuNeedsUpdate(_ menu: NSMenu) {
            let hidden = editing == nil
            for item in menu.items where item.tag == Self.editingItemTag {
                item.isHidden = hidden
            }
        }

        @objc func setCellNull(_ sender: Any?) {
            guard let editing, let tableView,
                  tableView.clickedRow >= 0, tableView.clickedColumn >= 0
            else { return }
            editing.onSetNull(tableView.clickedRow, tableView.clickedColumn)
        }

        @objc func revertCell(_ sender: Any?) {
            guard let editing, let tableView,
                  tableView.clickedRow >= 0, tableView.clickedColumn >= 0
            else { return }
            editing.onRevertCell(tableView.clickedRow, tableView.clickedColumn)
        }

        @objc func insertRow(_ sender: Any?) {
            editing?.onInsertRow()
        }

        @objc func deleteRows(_ sender: Any?) {
            guard let editing, let tableView else { return }
            var indexes = tableView.selectedRowIndexes
            if tableView.clickedRow >= 0, !indexes.contains(tableView.clickedRow) {
                indexes = IndexSet(integer: tableView.clickedRow)
            }
            guard !indexes.isEmpty else { return }
            editing.onDeleteRows(indexes)
        }

        // MARK: Cells

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let tableColumn,
                  let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn),
                  row < rows.count
            else { return nil }

            if let editing {
                return editableCell(
                    in: tableView, row: row, columnIndex: columnIndex, editing: editing)
            }
            return readOnlyCell(in: tableView, row: row, columnIndex: columnIndex)
        }

        private func readOnlyCell(
            in tableView: NSTableView, row: Int, columnIndex: Int
        ) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cellView: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? NSTableCellView {
                cellView = reused
            } else {
                cellView = Self.makeCellView(
                    identifier: identifier, field: NSTextField(labelWithString: ""))
            }

            let values = rows[row].values
            if columnIndex < values.count {
                let value = values[columnIndex]
                cellView.textField?.stringValue = value.displayString
                cellView.textField?.textColor = value.isNull
                    ? .tertiaryLabelColor : .labelColor
            } else {
                cellView.textField?.stringValue = ""
            }
            return cellView
        }

        private func editableCell(
            in tableView: NSTableView, row: Int, columnIndex: Int, editing: EditingConfig
        ) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("editcell")
            let cellView: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? NSTableCellView {
                cellView = reused
            } else {
                let field = NSTextField(string: "")
                field.isEditable = true
                field.isBordered = false
                field.drawsBackground = false
                field.focusRingType = .default
                field.delegate = self
                cellView = Self.makeCellView(identifier: identifier, field: field)
                cellView.wantsLayer = true
            }

            let display = editing.cellDisplay(row, columnIndex)
            guard let field = cellView.textField else { return cellView }
            field.stringValue = display.text
            field.placeholderString = display.placeholder.isEmpty ? nil : display.placeholder
            field.textColor = display.isNullStyle ? .tertiaryLabelColor : .labelColor
            let weight: NSFont.Weight = display.highlight == .edited ? .bold : .regular
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: weight)

            switch display.highlight {
            case .none:
                cellView.layer?.backgroundColor = nil
            case .edited:
                cellView.layer?.backgroundColor =
                    NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            case .deleted:
                cellView.layer?.backgroundColor =
                    NSColor.systemRed.withAlphaComponent(0.15).cgColor
            case .inserted:
                cellView.layer?.backgroundColor =
                    NSColor.systemGreen.withAlphaComponent(0.12).cgColor
            }
            return cellView
        }

        private static func makeCellView(
            identifier: NSUserInterfaceItemIdentifier, field: NSTextField
        ) -> NSTableCellView {
            let cellView = NSTableCellView()
            cellView.identifier = identifier
            field.font = .monospacedSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(field)
            cellView.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(
                    equalTo: cellView.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(
                    equalTo: cellView.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
            return cellView
        }

        // MARK: Edit commits

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let editing,
                  let field = notification.object as? NSTextField,
                  let cellView = field.superview as? NSTableCellView,
                  let tableView
            else { return }
            let row = tableView.row(for: cellView)
            let column = tableView.column(for: cellView)
            guard row >= 0, column >= 0 else { return }
            editing.onEdit(row, column, field.stringValue)
        }
    }
}
