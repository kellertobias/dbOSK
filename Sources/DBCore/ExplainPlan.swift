import Foundation

// MARK: - Normalized query plan

/// One operation in a normalized execution plan tree. Engine-specific plan
/// shapes (Postgres/MySQL JSON, SQLite EXPLAIN QUERY PLAN rows, MongoDB
/// explain documents) are parsed into this common model; keys the parser
/// doesn't map explicitly land in `properties` so nothing is lost.
public struct PlanNode: Sendable, Identifiable {
    /// Stable tree path ("0.1.2"), unique within one plan.
    public let id: String
    /// Operation name ("Seq Scan", "Nested Loop", "SEARCH", "IXSCAN"…).
    public let operation: String
    /// One-line condition/detail (index cond, filter, sort key…).
    public let detail: String?
    /// Table/collection the node operates on, when known.
    public let relation: String?
    public let indexName: String?
    /// Planner cost estimate, inclusive of children (engine units).
    public let estimatedCost: Double?
    public let estimatedRows: Double?
    /// Rows actually produced (per loop for Postgres); analyze only.
    public let actualRows: Double?
    /// Actual time in ms, inclusive of children (per loop for Postgres).
    public let actualTimeMs: Double?
    public let loops: Double?
    /// Remaining engine-specific keys, in display order.
    public let properties: [(String, String)]
    public let children: [PlanNode]

    public init(
        id: String,
        operation: String,
        detail: String? = nil,
        relation: String? = nil,
        indexName: String? = nil,
        estimatedCost: Double? = nil,
        estimatedRows: Double? = nil,
        actualRows: Double? = nil,
        actualTimeMs: Double? = nil,
        loops: Double? = nil,
        properties: [(String, String)] = [],
        children: [PlanNode] = []
    ) {
        self.id = id
        self.operation = operation
        self.detail = detail
        self.relation = relation
        self.indexName = indexName
        self.estimatedCost = estimatedCost
        self.estimatedRows = estimatedRows
        self.actualRows = actualRows
        self.actualTimeMs = actualTimeMs
        self.loops = loops
        self.properties = properties
        self.children = children
    }

    /// nil when leaf, so `OutlineGroup` hides the disclosure triangle.
    public var optionalChildren: [PlanNode]? {
        children.isEmpty ? nil : children
    }

    /// Total actual rows across loops (Postgres reports per-loop averages).
    public var totalActualRows: Double? {
        actualRows.map { $0 * max(loops ?? 1, 1) }
    }

    /// Total actual time across loops, inclusive of children.
    public var totalActualTimeMs: Double? {
        actualTimeMs.map { $0 * max(loops ?? 1, 1) }
    }

    /// Cost attributable to this node alone (inclusive minus children).
    public var selfCost: Double? {
        guard let estimatedCost else { return nil }
        let childSum = children.compactMap(\.estimatedCost).reduce(0, +)
        return max(estimatedCost - childSum, 0)
    }

    /// Time attributable to this node alone (inclusive minus children).
    public var selfTimeMs: Double? {
        guard let total = totalActualTimeMs else { return nil }
        let childSum = children.compactMap(\.totalActualTimeMs).reduce(0, +)
        return max(total - childSum, 0)
    }

    /// Whether the operation reads the whole table/collection.
    public var isFullScan: Bool {
        let op = operation.lowercased()
        if indexName != nil { return false }
        return op == "seq scan" || op == "collscan"
            || op.hasPrefix("full table scan")
            || (op == "scan" && !(detail ?? "").lowercased().contains("index"))
    }
}

/// A parsed execution plan plus the raw engine output for the JSON fallback.
public struct ExplainPlan: Sendable {
    public let root: PlanNode
    /// Unmodified plan document, for the raw view.
    public let raw: DBValue
    /// True when the query was actually executed (EXPLAIN ANALYZE /
    /// executionStats verbosity), i.e. actual metrics are meaningful.
    public let isAnalyze: Bool
    public let planningTimeMs: Double?
    public let executionTimeMs: Double?

    public init(
        root: PlanNode,
        raw: DBValue,
        isAnalyze: Bool,
        planningTimeMs: Double? = nil,
        executionTimeMs: Double? = nil
    ) {
        self.root = root
        self.raw = raw
        self.isAnalyze = isAnalyze
        self.planningTimeMs = planningTimeMs
        self.executionTimeMs = executionTimeMs
    }

    /// Denominator for cost-share bars (root cost is inclusive).
    public var totalCost: Double? { root.estimatedCost }

    /// Denominator for time-share bars.
    public var totalTimeMs: Double? { executionTimeMs ?? root.totalActualTimeMs }

    /// All nodes, pre-order.
    public var allNodes: [PlanNode] {
        func collect(_ node: PlanNode, into list: inout [PlanNode]) {
            list.append(node)
            for child in node.children { collect(child, into: &list) }
        }
        var list: [PlanNode] = []
        collect(root, into: &list)
        return list
    }
}

// MARK: - Warnings

extension PlanNode {
    /// Heuristic problems worth surfacing on the node's row.
    public func warnings(in plan: ExplainPlan) -> [String] {
        var warnings: [String] = []
        if isFullScan {
            let rows = estimatedRows ?? totalActualRows
            if let rows, rows >= 1000 {
                warnings.append(
                    "Full scan over ~\(Self.compact(rows)) rows — an index could help")
            } else if rows == nil {
                warnings.append(
                    "Full scan — consider an index if this table is large")
            }
        }
        if let estimated = estimatedRows, let actual = totalActualRows,
           estimated > 0, actual > 0 {
            let ratio = max(estimated, actual) / min(estimated, actual)
            if ratio > 10, max(estimated, actual) > 100 {
                warnings.append(
                    "Row estimate off by \(Self.compact(ratio))× "
                    + "(\(Self.compact(estimated)) estimated, \(Self.compact(actual)) actual) "
                    + "— statistics may be stale")
            }
        }
        if let share = costShare(in: plan), share > 0.5 {
            let metric = plan.isAnalyze && plan.totalTimeMs != nil ? "time" : "cost"
            warnings.append("Hottest node: \(Int(share * 100))% of total \(metric)")
        }
        return warnings
    }

    /// This node's share of the plan's total time (analyze) or cost, from its
    /// exclusive (self) metric. Nil when the engine reports neither.
    public func costShare(in plan: ExplainPlan) -> Double? {
        if plan.isAnalyze, let total = plan.totalTimeMs, total > 0,
           let selfTime = selfTimeMs {
            return min(selfTime / total, 1)
        }
        if let total = plan.totalCost, total > 0, let selfCost {
            return min(selfCost / total, 1)
        }
        return nil
    }

    /// Short human number for row counts and ratios ("15k", "1.2M").
    public static func compact(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", value / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}

// MARK: - Default driver implementation

extension DatabaseDriver {
    /// SQL-dialect default: wraps the statement per `ExplainStatementBuilder`,
    /// runs it through the normal execute path, and parses the result.
    public func explain(_ query: DriverQuery, analyze: Bool) async throws -> ExplainPlan {
        let descriptor = Self.descriptor
        guard descriptor.explainSupport != .none,
              case .sql(let sql) = query,
              let dialect = descriptor.sqlDialect
        else {
            throw DBError(
                kind: .unsupported,
                message: "\(descriptor.displayName) does not support Explain")
        }
        guard !analyze || descriptor.explainSupport == .planAndAnalyze else {
            throw DBError(
                kind: .unsupported,
                message: "\(descriptor.displayName) does not support Explain Analyze")
        }

        let statement = ExplainStatementBuilder.statement(
            for: sql, dialect: dialect, analyze: analyze)
        let execution = try await execute(.sql(statement), pageSize: 1000)
        var rows: [ResultRow] = []
        for try await chunk in execution.chunks {
            rows.append(contentsOf: chunk.rows)
        }
        return try ExplainPlanParser.parse(
            dialect: dialect, columns: execution.columns, rows: rows,
            isAnalyze: analyze)
    }
}

// MARK: - JSON bridging

extension DBValue {
    /// Converts a `JSONSerialization` object graph into `DBValue`s. Shared by
    /// drivers that surface JSON columns and by the explain-plan parsers.
    public static func fromJSONObject(_ object: Any) -> DBValue {
        switch object {
        case is NSNull: return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .double(number.doubleValue)
            }
            return .int(number.int64Value)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map { fromJSONObject($0) })
        case let dict as [String: Any]:
            return .document(dict.mapValues { fromJSONObject($0) })
        default: return .string(String(describing: object))
        }
    }

    /// Parses JSON text into a `DBValue`, nil when the text isn't valid JSON.
    public static func fromJSONText(_ text: String) -> DBValue? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return nil }
        return fromJSONObject(object)
    }

    /// Numeric coercion helper for plan metrics ("12.5", 12, 12.5 all work).
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .decimal(let s), .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
}
