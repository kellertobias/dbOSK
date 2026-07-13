import DBCore
import SwiftUI

/// Two-column results for document-shaped rows (MongoDB, jsonb-only results):
/// a narrow row list on the left, tree or raw-JSON detail on the right.
/// The tree/JSON choice is owned by the enclosing `ResultsArea` view picker.
struct DocumentResultsView: View {
    let rows: [ResultRow]
    var detailMode: DetailMode = .tree
    @State private var selectedRowID: Int?

    enum DetailMode {
        case tree
        case json
    }

    var body: some View {
        HSplitView {
            List(rows, selection: $selectedRowID) { row in
                Text(summary(for: row))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .tag(row.id)
            }
            .frame(minWidth: 160, idealWidth: 240, maxWidth: 400)
            detail
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: rows.count) { selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        if selectedRowID == nil, let first = rows.first {
            selectedRowID = first.id
        }
    }

    private var selectedValue: DBValue? {
        guard let selectedRowID,
              let row = rows.first(where: { $0.id == selectedRowID })
        else { return nil }
        return row.values.first
    }

    @ViewBuilder
    private var detail: some View {
        if let value = selectedValue {
            VStack(spacing: 0) {
                switch detailMode {
                case .tree:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            OutlineGroup(
                                ValueNode.children(of: value, parentID: "root") ?? [],
                                children: \.children
                            ) { node in
                                HStack(spacing: 6) {
                                    Text(node.key)
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(node.preview)
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .json:
                    ScrollView {
                        Text(value.jsonString(prettyPrinted: true))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No Row Selected", systemImage: "doc.text",
                description: Text("Select an entry on the left."))
        }
    }

    private func summary(for row: ResultRow) -> String {
        guard case .document(let doc)? = row.values.first else {
            return row.values.first?.displayString ?? ""
        }
        if let id = doc["_id"] {
            return "\(row.id + 1)  \(id.displayString)"
        }
        return "\(row.id + 1)  \(row.values.first?.displayString ?? "")"
    }
}

/// Tree node adapter for DBValue documents/arrays.
struct ValueNode: Identifiable {
    let id: String
    let key: String
    let value: DBValue

    var children: [ValueNode]? {
        Self.children(of: value, parentID: id)
    }

    var preview: String {
        switch value {
        case .document(let dict): return "{…} \(dict.count) fields"
        case .array(let items): return "[…] \(items.count) items"
        default: return value.displayString
        }
    }

    static func children(of value: DBValue, parentID: String) -> [ValueNode]? {
        switch value {
        case .document(let dict):
            return dict.keys.sorted().map { key in
                ValueNode(id: "\(parentID).\(key)", key: key, value: dict[key]!)
            }
        case .array(let items):
            return items.enumerated().map { index, item in
                ValueNode(id: "\(parentID)[\(index)]", key: "[\(index)]", value: item)
            }
        default:
            return nil
        }
    }
}
