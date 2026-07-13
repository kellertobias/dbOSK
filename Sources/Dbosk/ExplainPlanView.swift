import DBCore
import SwiftUI

/// Visual query-plan panel shown in place of the results area after
/// "Explain". Left: the plan as an indented operation tree with per-node
/// metrics, cost-share bars, and warning badges. Right: details of the
/// selected node. A Raw toggle shows the engine's original plan document.
struct ExplainPlanView: View {
    let plan: ExplainPlan
    let onClose: () -> Void

    private enum DisplayMode: String, CaseIterable {
        case tree = "Tree"
        case raw = "Raw"
    }

    @State private var displayMode: DisplayMode = .tree
    @State private var selectedNodeID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch displayMode {
            case .tree:
                HSplitView {
                    nodeList
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    nodeDetail
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 480, maxHeight: .infinity)
                }
            case .raw:
                ScrollView {
                    Text(plan.raw.jsonString(prettyPrinted: true))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
        .onAppear { selectedNodeID = plan.root.id }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Label(
                plan.isAnalyze ? "Query Plan — Analyzed" : "Query Plan",
                systemImage: "list.bullet.indent")
                .font(.caption.bold())
            if let timing = timingSummary {
                Text(timing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("View", selection: $displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close the plan and show results again")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var timingSummary: String? {
        var parts: [String] = []
        if let planning = plan.planningTimeMs {
            parts.append("Planning \(Self.milliseconds(planning))")
        }
        if let execution = plan.executionTimeMs {
            parts.append("Execution \(Self.milliseconds(execution))")
        }
        if parts.isEmpty, let cost = plan.totalCost {
            parts.append("Total cost \(PlanNode.compact(cost))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Tree

    /// The plan flattened depth-first; plans are small, and showing every
    /// node expanded with indentation reads better than disclosure triangles.
    private var flattenedNodes: [(node: PlanNode, depth: Int)] {
        var result: [(PlanNode, Int)] = []
        func walk(_ node: PlanNode, depth: Int) {
            result.append((node, depth))
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(plan.root, depth: 0)
        return result
    }

    private var nodeList: some View {
        List(selection: $selectedNodeID) {
            ForEach(flattenedNodes, id: \.node.id) { entry in
                ExplainNodeRow(node: entry.node, depth: entry.depth, plan: plan)
                    .tag(entry.node.id)
            }
        }
        .listStyle(.inset)
    }

    // MARK: Detail

    @ViewBuilder
    private var nodeDetail: some View {
        if let node = plan.allNodes.first(where: { $0.id == selectedNodeID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(node.operation)
                        .font(.headline)
                    ForEach(node.warnings(in: plan), id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    detailRows(for: node)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No Node Selected", systemImage: "list.bullet.indent",
                description: Text("Select an operation on the left."))
        }
    }

    private func detailRows(for node: PlanNode) -> some View {
        var rows: [(String, String)] = []
        if let relation = node.relation { rows.append(("Relation", relation)) }
        if let index = node.indexName { rows.append(("Index", index)) }
        if let cost = node.estimatedCost {
            rows.append(("Estimated cost", PlanNode.compact(cost)))
        }
        if let rowsEstimate = node.estimatedRows {
            rows.append(("Estimated rows", PlanNode.compact(rowsEstimate)))
        }
        if let actual = node.totalActualRows {
            rows.append(("Actual rows", PlanNode.compact(actual)))
        }
        if let time = node.totalActualTimeMs {
            rows.append(("Actual time", Self.milliseconds(time)))
        }
        if let loops = node.loops, loops > 1 {
            rows.append(("Loops", PlanNode.compact(loops)))
        }
        if let detail = node.detail { rows.append(("Condition", detail)) }
        rows.append(contentsOf: node.properties)

        return Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.1)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    static func milliseconds(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.2f s", value / 1000) }
        if value >= 10 { return String(format: "%.0f ms", value) }
        return String(format: "%.2f ms", value)
    }
}

/// One operation row: indented name + target, right-aligned metrics and a
/// cost-share bar sized to the node's exclusive share of the plan total.
private struct ExplainNodeRow: View {
    let node: PlanNode
    let depth: Int
    let plan: ExplainPlan

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(node.operation)
                        .font(.system(.callout, design: .monospaced).bold())
                    if !node.warnings(in: plan).isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(node.warnings(in: plan).joined(separator: "\n"))
                    }
                }
                if let target = targetText {
                    Text(target)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if let metrics = metricsText {
                    Text(metrics)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let share = node.costShare(in: plan) {
                    shareBar(share)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .padding(.vertical, 1)
    }

    private var targetText: String? {
        var parts: [String] = []
        if let relation = node.relation { parts.append("on \(relation)") }
        if let index = node.indexName { parts.append("using \(index)") }
        if parts.isEmpty, let detail = node.detail { return detail }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var metricsText: String? {
        var parts: [String] = []
        if let cost = node.estimatedCost {
            parts.append("cost \(PlanNode.compact(cost))")
        }
        switch (node.estimatedRows, node.totalActualRows) {
        case (let estimated?, let actual?):
            parts.append("rows \(PlanNode.compact(estimated)) est / \(PlanNode.compact(actual)) actual")
        case (let estimated?, nil):
            parts.append("rows \(PlanNode.compact(estimated)) est")
        case (nil, let actual?):
            parts.append("rows \(PlanNode.compact(actual))")
        case (nil, nil):
            break
        }
        if let time = node.totalActualTimeMs {
            parts.append(ExplainPlanView.milliseconds(time))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func shareBar(_ share: Double) -> some View {
        let width: CGFloat = 96
        return ZStack(alignment: .trailing) {
            Capsule()
                .fill(.quaternary)
                .frame(width: width, height: 4)
            Capsule()
                .fill(barColor(share))
                .frame(width: max(width * share, 3), height: 4)
        }
        .help("\(Int(share * 100))% of total \(plan.isAnalyze ? "time" : "cost")")
    }

    private func barColor(_ share: Double) -> Color {
        switch share {
        case ..<0.1: return .green
        case ..<0.3: return .yellow
        case ..<0.6: return .orange
        default: return .red
        }
    }
}
