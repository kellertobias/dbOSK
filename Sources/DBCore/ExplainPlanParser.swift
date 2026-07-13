import Foundation

/// Parses engine-specific EXPLAIN output into the normalized `ExplainPlan`
/// tree. Pure functions over `DBValue` rows, unit-testable without a live
/// database. Parsers are tolerant: unmapped keys land in `properties` and
/// unknown containers become generic child nodes, so version drift degrades
/// instead of failing — and the raw document stays viewable regardless.
public enum ExplainPlanParser {
    public static func parse(
        dialect: SQLDialect,
        columns: [ColumnMeta],
        rows: [ResultRow],
        isAnalyze: Bool
    ) throws -> ExplainPlan {
        switch dialect {
        case .postgres:
            return try parsePostgres(rows: rows, isAnalyze: isAnalyze)
        case .mysql:
            return try parseMySQL(rows: rows, isAnalyze: isAnalyze)
        case .sqlite:
            return try parseSQLite(columns: columns, rows: rows)
        }
    }

    static func parseError(_ detail: String) -> DBError {
        DBError(
            kind: .queryFailed,
            message: "Could not parse the execution plan",
            underlying: detail)
    }

    /// Reassembles the plan document from the result set: JSON columns arrive
    /// pre-parsed as `.document`/`.array`; text output arrives as one or more
    /// string rows that are joined and JSON-decoded.
    private static func firstValueAsJSON(_ rows: [ResultRow]) throws -> DBValue {
        guard let first = rows.first?.values.first else {
            throw parseError("The server returned no plan rows")
        }
        switch first {
        case .document, .array:
            return first
        case .string, .unsupported:
            let text = rows
                .compactMap { row -> String? in
                    switch row.values.first {
                    case .string(let s): return s
                    case .unsupported(_, let s): return s
                    default: return nil
                    }
                }
                .joined(separator: "\n")
            guard let value = DBValue.fromJSONText(text) else {
                throw parseError("Plan output is not valid JSON")
            }
            return value
        default:
            throw parseError("Unexpected plan value type")
        }
    }
}

// MARK: - PostgreSQL (EXPLAIN [ANALYZE] (FORMAT JSON))

extension ExplainPlanParser {
    static func parsePostgres(rows: [ResultRow], isAnalyze: Bool) throws -> ExplainPlan {
        let raw = try firstValueAsJSON(rows)
        // FORMAT JSON yields an array with one entry per statement.
        var top = raw
        if case .array(let items) = top, let first = items.first { top = first }
        guard case .document(let doc) = top,
              case .document(let planDoc)? = doc["Plan"]
        else { throw parseError("Missing \"Plan\" object") }

        return ExplainPlan(
            root: postgresNode(planDoc, id: "0"),
            raw: raw,
            isAnalyze: isAnalyze,
            planningTimeMs: doc["Planning Time"]?.doubleValue,
            executionTimeMs: doc["Execution Time"]?.doubleValue)
    }

    /// Keys rendered as the node's one-line detail, in priority order.
    private static let postgresConditionKeys = [
        "Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond",
        "Join Filter", "Filter", "Sort Key", "Group Key",
    ]

    private static let postgresMappedKeys: Set<String> = [
        "Node Type", "Relation Name", "Index Name", "Total Cost", "Plan Rows",
        "Actual Rows", "Actual Total Time", "Actual Loops", "Plans",
    ]

    private static func postgresNode(_ doc: [String: DBValue], id: String) -> PlanNode {
        var children: [PlanNode] = []
        if case .array(let subplans)? = doc["Plans"] {
            for (index, subplan) in subplans.enumerated() {
                guard case .document(let subdoc) = subplan else { continue }
                children.append(postgresNode(subdoc, id: "\(id).\(index)"))
            }
        }

        let detail = postgresConditionKeys
            .compactMap { key in doc[key].map { "\(key): \($0.displayString)" } }
            .joined(separator: " · ")

        let handled = postgresMappedKeys.union(postgresConditionKeys)
        let properties = doc.keys.sorted()
            .filter { !handled.contains($0) }
            .map { ($0, doc[$0]!.displayString) }

        return PlanNode(
            id: id,
            operation: doc["Node Type"]?.displayString ?? "Unknown",
            detail: detail.isEmpty ? nil : detail,
            relation: doc["Relation Name"]?.displayString,
            indexName: doc["Index Name"]?.displayString,
            estimatedCost: doc["Total Cost"]?.doubleValue,
            estimatedRows: doc["Plan Rows"]?.doubleValue,
            actualRows: doc["Actual Rows"]?.doubleValue,
            actualTimeMs: doc["Actual Total Time"]?.doubleValue,
            loops: doc["Actual Loops"]?.doubleValue,
            properties: properties,
            children: children)
    }
}

// MARK: - MySQL (EXPLAIN FORMAT=JSON)

extension ExplainPlanParser {
    static func parseMySQL(rows: [ResultRow], isAnalyze: Bool) throws -> ExplainPlan {
        let raw = try firstValueAsJSON(rows)
        guard case .document(let doc) = raw else {
            throw parseError("Expected a JSON object")
        }
        let root: PlanNode
        if case .document(let block)? = doc["query_block"] {
            root = mysqlNode(key: "query_block", doc: block, id: "0")
        } else {
            // Unknown top-level shape (format drift): generic tree.
            root = mysqlNode(key: "query", doc: doc, id: "0")
        }
        return ExplainPlan(root: root, raw: raw, isAnalyze: isAnalyze)
    }

    private static let mysqlOperationNames: [String: String] = [
        "query_block": "Query Block",
        "nested_loop": "Nested Loop",
        "ordering_operation": "Sort",
        "grouping_operation": "Group",
        "duplicates_removal": "Distinct",
        "materialized_from_subquery": "Materialize",
        "attached_subqueries": "Subqueries",
        "optimized_away_subqueries": "Optimized Subqueries",
        "union_result": "Union",
        "buffer_result": "Buffer",
        "windowing": "Window",
        "table": "Table",
        "query": "Query",
        "query_specifications": "Query Branches",
        "insert_from": "Insert From",
        "update_value_expressions": "Update Values",
    ]

    private static let mysqlAccessTypes: [String: String] = [
        "ALL": "Full Table Scan",
        "index": "Full Index Scan",
        "range": "Index Range Scan",
        "ref": "Index Lookup",
        "ref_or_null": "Index Lookup (or NULL)",
        "eq_ref": "Unique Index Lookup",
        "const": "Constant Lookup",
        "system": "System Row",
        "fulltext": "Fulltext Search",
        "index_merge": "Index Merge",
    ]

    private static func mysqlOperation(for key: String) -> String {
        if let known = mysqlOperationNames[key] { return known }
        return key.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Generic tolerant walker: scalar values become properties, object and
    /// array values become child nodes — so unknown format versions still
    /// produce a sensible tree. `table` objects get first-class mapping.
    private static func mysqlNode(
        key: String, doc: [String: DBValue], id: String
    ) -> PlanNode {
        let isTable = key == "table" && doc["table_name"] != nil

        var relation: String?
        var indexName: String?
        var operation = mysqlOperation(for: key)
        var detail: String?
        var estimatedCost: Double?
        var estimatedRows: Double?
        var actualRows: Double?
        var actualTimeMs: Double?
        var properties: [(String, String)] = []
        var children: [PlanNode] = []

        for key in doc.keys.sorted() {
            let value = doc[key]!
            switch (key, value) {
            case ("table_name", _) where isTable:
                relation = value.displayString
            case ("access_type", .string(let type)) where isTable:
                operation = mysqlAccessTypes[type] ?? "Access: \(type)"
            case ("key", _) where isTable:
                indexName = value.displayString
            case ("attached_condition", _):
                detail = value.displayString
            case ("rows_examined_per_scan", _), ("rows", _):
                estimatedRows = estimatedRows ?? value.doubleValue
            // Format version 2 (MySQL 8.3+) actual metrics, when present.
            case ("actual_rows", _):
                actualRows = value.doubleValue
            case ("actual_last_row_ms", _):
                actualTimeMs = value.doubleValue
            case ("cost_info", .document(let costs)):
                estimatedCost = costs["prefix_cost"]?.doubleValue
                    ?? costs["query_cost"]?.doubleValue
                    ?? costs["read_cost"]?.doubleValue
                for costKey in costs.keys.sorted() {
                    properties.append((costKey, costs[costKey]!.displayString))
                }
            case (_, .document(let subdoc)):
                children.append(
                    mysqlNode(key: key, doc: subdoc, id: "\(id).\(children.count)"))
            case (_, .array(let items)):
                let childID = "\(id).\(children.count)"
                children.append(PlanNode(
                    id: childID,
                    operation: mysqlOperation(for: key),
                    children: mysqlChildren(
                        of: items, containerKey: key, id: childID, startIndex: 0)))
            default:
                properties.append((key, value.displayString))
            }
        }

        return PlanNode(
            id: id,
            operation: operation,
            detail: detail,
            relation: relation,
            indexName: indexName,
            estimatedCost: estimatedCost,
            estimatedRows: estimatedRows,
            actualRows: actualRows,
            actualTimeMs: actualTimeMs,
            properties: properties,
            children: children)
    }

    /// Array containers (`nested_loop`, `query_specifications`…) hold items
    /// that are usually single-key wrappers like `{"table": {…}}` — unwrap
    /// those; anything else becomes a generic node named after the container.
    private static func mysqlChildren(
        of items: [DBValue], containerKey: String, id: String, startIndex: Int
    ) -> [PlanNode] {
        var children: [PlanNode] = []
        for item in items {
            guard case .document(let doc) = item else { continue }
            let childID = "\(id).\(startIndex + children.count)"
            if doc.count == 1, let onlyKey = doc.keys.first,
               case .document(let inner)? = doc[onlyKey] {
                children.append(mysqlNode(key: onlyKey, doc: inner, id: childID))
            } else {
                children.append(mysqlNode(key: containerKey, doc: doc, id: childID))
            }
        }
        return children
    }
}

// MARK: - SQLite (EXPLAIN QUERY PLAN)

extension ExplainPlanParser {
    static func parseSQLite(columns: [ColumnMeta], rows: [ResultRow]) throws -> ExplainPlan {
        func columnIndex(_ name: String, fallback: Int) -> Int {
            columns.firstIndex { $0.name.lowercased() == name } ?? fallback
        }
        let idIndex = columnIndex("id", fallback: 0)
        let parentIndex = columnIndex("parent", fallback: 1)
        let detailIndex = columnIndex("detail", fallback: 3)

        struct Entry {
            let id: Int
            let parent: Int
            let detail: String
        }
        let entries: [Entry] = rows.compactMap { row in
            guard row.values.indices.contains(detailIndex) else { return nil }
            func int(_ index: Int) -> Int {
                guard row.values.indices.contains(index) else { return 0 }
                return Int(row.values[index].doubleValue ?? 0)
            }
            return Entry(
                id: int(idIndex),
                parent: int(parentIndex),
                detail: row.values[detailIndex].displayString)
        }
        guard !entries.isEmpty else {
            throw parseError("EXPLAIN QUERY PLAN returned no rows")
        }

        let knownIDs = Set(entries.map(\.id))
        let byParent = Dictionary(grouping: entries, by: \.parent)

        func node(for entry: Entry, id: String) -> PlanNode {
            let children = (byParent[entry.id] ?? []).enumerated().map {
                node(for: $1, id: "\(id).\($0)")
            }
            let parsed = sqliteDetail(entry.detail)
            return PlanNode(
                id: id,
                operation: parsed.operation,
                detail: entry.detail,
                relation: parsed.relation,
                indexName: parsed.indexName,
                children: children)
        }

        let rootEntries = entries.filter { !knownIDs.contains($0.parent) }
        let roots = rootEntries.enumerated().map { node(for: $1, id: "0.\($0)") }
        let root = roots.count == 1
            ? roots[0]
            : PlanNode(id: "0", operation: "Query Plan", children: roots)

        // Raw view: the EQP rows as documents.
        let raw = DBValue.array(entries.map {
            .document([
                "id": .int(Int64($0.id)),
                "parent": .int(Int64($0.parent)),
                "detail": .string($0.detail),
            ])
        })
        return ExplainPlan(root: root, raw: raw, isAnalyze: false)
    }

    /// Splits an EQP detail line ("SEARCH t USING INDEX idx (a=?)") into the
    /// leading upper-case operation, the target table, and the index name.
    private static func sqliteDetail(
        _ detail: String
    ) -> (operation: String, relation: String?, indexName: String?) {
        let tokens = detail.split(separator: " ").map(String.init)

        let operation: String
        var relation: String?
        if let first = tokens.first, ["SCAN", "SEARCH"].contains(first) {
            operation = first
            var rest = tokens.dropFirst()
            if rest.first == "TABLE" { rest = rest.dropFirst() }  // pre-3.36 wording
            relation = rest.first
        } else {
            // "USE TEMP B-TREE FOR ORDER BY", "CO-ROUTINE x": the leading
            // upper-case words are the operation.
            var operationTokens: [String] = []
            for token in tokens {
                guard token == token.uppercased(),
                      token.rangeOfCharacter(from: .letters) != nil
                else { break }
                operationTokens.append(token)
            }
            if operationTokens.isEmpty { operationTokens = [tokens.first ?? detail] }
            operation = operationTokens.joined(separator: " ")
        }

        var indexName: String?
        for marker in ["USING COVERING INDEX ", "USING INDEX "] {
            if let range = detail.range(of: marker) {
                let tail = detail[range.upperBound...]
                indexName = tail.split(separator: " ").first.map(String.init)
                break
            }
        }
        return (operation, relation, indexName)
    }
}

// MARK: - MongoDB (explain command reply)

extension ExplainPlanParser {
    /// Parses the reply of `{explain: …, verbosity: …}`. Handles plain
    /// find/count explains (top-level `queryPlanner`) and aggregate explains
    /// (`stages` array whose first entry holds a `$cursor` plan).
    public static func parseMongo(reply: DBValue, isAnalyze: Bool) throws -> ExplainPlan {
        guard case .document(let doc) = reply else {
            throw parseError("Expected an explain document")
        }

        if doc["queryPlanner"] != nil || doc["executionStats"] != nil {
            let root = try mongoPlanRoot(doc, id: "0")
            return ExplainPlan(
                root: root,
                raw: reply,
                isAnalyze: isAnalyze,
                executionTimeMs: mongoExecutionTime(doc))
        }

        if case .array(let stages)? = doc["stages"] {
            var children: [PlanNode] = []
            var executionTime: Double?
            for (index, stage) in stages.enumerated() {
                guard case .document(let stageDoc) = stage,
                      let key = stageDoc.keys.first
                else { continue }
                let id = "0.\(index)"
                if key == "$cursor", case .document(let cursor)? = stageDoc["$cursor"] {
                    children.append(try mongoPlanRoot(cursor, id: id))
                    executionTime = executionTime ?? mongoExecutionTime(cursor)
                } else if case .document(let inner)? = stageDoc[key] {
                    children.append(mongoStageNode(inner, operation: key, id: id))
                } else {
                    children.append(PlanNode(id: id, operation: key))
                }
            }
            guard !children.isEmpty else {
                throw parseError("Aggregate explain has no stages")
            }
            let root = PlanNode(
                id: "0", operation: "Aggregation Pipeline", children: children)
            return ExplainPlan(
                root: root, raw: reply, isAnalyze: isAnalyze,
                executionTimeMs: executionTime)
        }

        throw parseError("Unrecognized explain document shape")
    }

    /// Prefers the executionStats tree (has actual rows/timings) and falls
    /// back to the planner's winning plan.
    private static func mongoPlanRoot(
        _ doc: [String: DBValue], id: String
    ) throws -> PlanNode {
        var namespace: String?
        if case .document(let planner)? = doc["queryPlanner"] {
            namespace = planner["namespace"]?.displayString
        }
        if case .document(let stats)? = doc["executionStats"],
           case .document(let stages)? = stats["executionStages"] {
            return mongoStageNode(stages, id: id, relation: namespace)
        }
        if case .document(let planner)? = doc["queryPlanner"],
           case .document(let winning)? = planner["winningPlan"] {
            return mongoStageNode(winning, id: id, relation: namespace)
        }
        throw parseError("Missing winningPlan/executionStages")
    }

    private static func mongoExecutionTime(_ doc: [String: DBValue]) -> Double? {
        guard case .document(let stats)? = doc["executionStats"] else { return nil }
        return stats["executionTimeMillis"]?.doubleValue
    }

    private static let mongoMappedKeys: Set<String> = [
        "stage", "indexName", "filter", "nReturned",
        "executionTimeMillisEstimate", "inputStage", "inputStages", "shards",
    ]

    private static func mongoStageNode(
        _ doc: [String: DBValue],
        operation: String? = nil,
        id: String,
        relation: String? = nil
    ) -> PlanNode {
        var children: [PlanNode] = []
        if case .document(let input)? = doc["inputStage"] {
            children.append(mongoStageNode(input, id: "\(id).0"))
        }
        for containerKey in ["inputStages", "shards"] {
            guard case .array(let items)? = doc[containerKey] else { continue }
            for item in items {
                guard case .document(let itemDoc) = item else { continue }
                children.append(
                    mongoStageNode(itemDoc, id: "\(id).\(children.count)"))
            }
        }

        var detail: String?
        if case .document(let filter)? = doc["filter"], !filter.isEmpty {
            detail = "filter: \(DBValue.document(filter).displayString)"
        }

        let properties = doc.keys.sorted()
            .filter { !mongoMappedKeys.contains($0) }
            .compactMap { key -> (String, String)? in
                let value = doc[key]!
                // Nested plan internals (e.g. shard sub-documents already
                // shown as children) would be noise as JSON blobs.
                if case .document = value { return nil }
                return (key, value.displayString)
            }

        return PlanNode(
            id: id,
            operation: operation ?? doc["stage"]?.displayString ?? "Stage",
            detail: detail,
            relation: relation,
            indexName: doc["indexName"]?.displayString,
            actualRows: doc["nReturned"]?.doubleValue,
            actualTimeMs: doc["executionTimeMillisEstimate"]?.doubleValue,
            properties: properties,
            children: children)
    }
}
