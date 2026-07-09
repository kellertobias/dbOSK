import AppKit
import DBCore
import SwiftUI

/// View-based NSTableView for large result sets. Reloads when `version` changes;
/// rows are looked up lazily so appending while streaming stays cheap.
struct ResultsTableView: NSViewRepresentable {
    let columns: [ColumnMeta]
    let rows: [ResultRow]
    let version: Int

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

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
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
        } else if rows.count > previousRowCount, previousRowCount > 0 {
            tableView.insertRows(
                at: IndexSet(integersIn: previousRowCount..<rows.count),
                withAnimation: [])
        } else {
            tableView.reloadData()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var columns: [ColumnMeta] = []
        var rows: [ResultRow] = []
        var version = -1
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

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let tableColumn,
                  let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn),
                  row < rows.count
            else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cellView: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? NSTableCellView {
                cellView = reused
            } else {
                cellView = NSTableCellView()
                cellView.identifier = identifier
                let field = NSTextField(labelWithString: "")
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
    }
}
