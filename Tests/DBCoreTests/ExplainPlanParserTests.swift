import Foundation
import Testing

@testable import DBCore

@Suite struct ExplainStatementBuilderTests {
    @Test func postgresStatements() {
        #expect(
            ExplainStatementBuilder.statement(
                for: "SELECT 1;", dialect: .postgres, analyze: false)
            == "EXPLAIN (FORMAT JSON) SELECT 1")
        #expect(
            ExplainStatementBuilder.statement(
                for: "SELECT 1", dialect: .postgres, analyze: true)
            == "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT 1")
    }

    @Test func mysqlAndSQLiteStatements() {
        #expect(
            ExplainStatementBuilder.statement(
                for: "SELECT 1", dialect: .mysql, analyze: false)
            == "EXPLAIN FORMAT=JSON SELECT 1")
        #expect(
            ExplainStatementBuilder.statement(
                for: " SELECT 1 ; ", dialect: .sqlite, analyze: false)
            == "EXPLAIN QUERY PLAN SELECT 1")
    }

    @Test func readOnlyDetection() {
        #expect(ExplainStatementBuilder.isReadOnlyStatement("SELECT * FROM t"))
        #expect(ExplainStatementBuilder.isReadOnlyStatement("select\n1"))
        #expect(ExplainStatementBuilder.isReadOnlyStatement("WITH x AS (SELECT 1) SELECT * FROM x"))
        #expect(ExplainStatementBuilder.isReadOnlyStatement("(SELECT 1)"))
        #expect(!ExplainStatementBuilder.isReadOnlyStatement("UPDATE t SET a = 1"))
        #expect(!ExplainStatementBuilder.isReadOnlyStatement("DELETE FROM t"))
        #expect(!ExplainStatementBuilder.isReadOnlyStatement(""))
    }
}

@Suite struct ExplainPlanParserTests {
    private func jsonRows(_ json: String) -> [ResultRow] {
        [ResultRow(id: 0, values: [DBValue.fromJSONText(json)!])]
    }

    // MARK: Postgres

    private let postgresAnalyzeJSON = """
        [{
          "Plan": {
            "Node Type": "Hash Join",
            "Join Type": "Inner",
            "Total Cost": 100.5,
            "Plan Rows": 500,
            "Actual Rows": 40,
            "Actual Total Time": 12.5,
            "Actual Loops": 1,
            "Hash Cond": "(o.user_id = u.id)",
            "Plans": [
              {
                "Node Type": "Seq Scan",
                "Relation Name": "orders",
                "Total Cost": 60.0,
                "Plan Rows": 5000,
                "Actual Rows": 5000,
                "Actual Total Time": 8.0,
                "Actual Loops": 1,
                "Filter": "(status = 'open')"
              },
              {
                "Node Type": "Index Scan",
                "Relation Name": "users",
                "Index Name": "users_pkey",
                "Total Cost": 20.0,
                "Plan Rows": 100,
                "Actual Rows": 2,
                "Actual Total Time": 0.5,
                "Actual Loops": 40
              }
            ]
          },
          "Planning Time": 0.2,
          "Execution Time": 13.1
        }]
        """

    @Test func postgresAnalyzePlan() throws {
        let plan = try ExplainPlanParser.parse(
            dialect: .postgres, columns: [],
            rows: jsonRows(postgresAnalyzeJSON), isAnalyze: true)

        #expect(plan.isAnalyze)
        #expect(plan.planningTimeMs == 0.2)
        #expect(plan.executionTimeMs == 13.1)
        #expect(plan.root.operation == "Hash Join")
        #expect(plan.root.detail == "Hash Cond: (o.user_id = u.id)")
        #expect(plan.root.children.count == 2)

        let scan = plan.root.children[0]
        #expect(scan.operation == "Seq Scan")
        #expect(scan.relation == "orders")
        #expect(scan.detail == "Filter: (status = 'open')")
        #expect(scan.isFullScan)

        let index = plan.root.children[1]
        #expect(index.indexName == "users_pkey")
        #expect(!index.isFullScan)
        // Per-loop values scale by loop count.
        #expect(index.totalActualRows == 80)
        #expect(index.totalActualTimeMs == 20)

        // Unmapped keys survive as properties.
        #expect(plan.root.properties.contains { $0.0 == "Join Type" && $0.1 == "Inner" })

        // Exclusive metrics subtract children.
        #expect(plan.root.selfCost == 20.5)

        // Warnings: seq scan over 5k rows, index misestimate (100 est vs 80
        // actual is under 10x, fine), hot node on the seq scan (8ms of 13.1).
        #expect(scan.warnings(in: plan).contains { $0.contains("Full scan") })
        #expect(scan.warnings(in: plan).contains { $0.contains("Hottest node") })
    }

    @Test func postgresTextRowsAreJoinedAndDecoded() throws {
        // Some paths surface the json column as text rows.
        let lines = postgresAnalyzeJSON.split(separator: "\n").map(String.init)
        let rows = lines.enumerated().map { index, line in
            ResultRow(id: index, values: [.string(line)])
        }
        let plan = try ExplainPlanParser.parse(
            dialect: .postgres, columns: [], rows: rows, isAnalyze: true)
        #expect(plan.root.operation == "Hash Join")
    }

    @Test func postgresMisestimateWarning() throws {
        let json = """
            [{"Plan": {
                "Node Type": "Seq Scan", "Relation Name": "t",
                "Total Cost": 10, "Plan Rows": 10,
                "Actual Rows": 5000, "Actual Loops": 1
            }}]
            """
        let plan = try ExplainPlanParser.parse(
            dialect: .postgres, columns: [], rows: jsonRows(json), isAnalyze: true)
        #expect(plan.root.warnings(in: plan).contains { $0.contains("estimate off") })
    }

    @Test func postgresMissingPlanThrows() {
        #expect(throws: DBError.self) {
            try ExplainPlanParser.parse(
                dialect: .postgres, columns: [],
                rows: jsonRows(#"[{"Something": 1}]"#), isAnalyze: false)
        }
    }

    // MARK: MySQL

    @Test func mysqlNestedLoopPlan() throws {
        let json = """
            {
              "query_block": {
                "select_id": 1,
                "cost_info": {"query_cost": "830.90"},
                "nested_loop": [
                  {"table": {
                    "table_name": "users",
                    "access_type": "ALL",
                    "rows_examined_per_scan": 4000,
                    "cost_info": {"read_cost": "100.0", "eval_cost": "40.0", "prefix_cost": "440.0"}
                  }},
                  {"table": {
                    "table_name": "orders",
                    "access_type": "ref",
                    "key": "idx_user_id",
                    "rows_examined_per_scan": 2,
                    "attached_condition": "(orders.status = 'open')"
                  }}
                ]
              }
            }
            """
        let plan = try ExplainPlanParser.parse(
            dialect: .mysql, columns: [], rows: jsonRows(json), isAnalyze: false)

        #expect(plan.root.operation == "Query Block")
        #expect(plan.root.estimatedCost == 830.90)
        let loop = try #require(plan.root.children.first)
        #expect(loop.operation == "Nested Loop")
        #expect(loop.children.count == 2)

        let users = loop.children[0]
        #expect(users.operation == "Full Table Scan")
        #expect(users.relation == "users")
        #expect(users.estimatedRows == 4000)
        #expect(users.estimatedCost == 440.0)
        #expect(users.isFullScan)
        #expect(users.warnings(in: plan).contains { $0.contains("Full scan") })

        let orders = loop.children[1]
        #expect(orders.operation == "Index Lookup")
        #expect(orders.indexName == "idx_user_id")
        #expect(orders.detail == "(orders.status = 'open')")
    }

    @Test func mysqlUnknownShapeDegradesToGenericTree() throws {
        // Simulates format drift: unknown container keys become generic nodes.
        let json = """
            {
              "query_block": {
                "select_id": 1,
                "shiny_new_operation": {
                  "some_flag": true,
                  "table": {"table_name": "t", "access_type": "range", "key": "idx_a"}
                }
              }
            }
            """
        let plan = try ExplainPlanParser.parse(
            dialect: .mysql, columns: [], rows: jsonRows(json), isAnalyze: false)
        let unknown = try #require(plan.root.children.first)
        #expect(unknown.operation == "Shiny New Operation")
        #expect(unknown.properties.contains { $0.0 == "some_flag" })
        let table = try #require(unknown.children.first)
        #expect(table.operation == "Index Range Scan")
        #expect(table.relation == "t")
    }

    // MARK: SQLite

    private let sqliteColumns = [
        ColumnMeta(name: "id", dbTypeName: "int"),
        ColumnMeta(name: "parent", dbTypeName: "int"),
        ColumnMeta(name: "notused", dbTypeName: "int"),
        ColumnMeta(name: "detail", dbTypeName: "text"),
    ]

    private func sqliteRow(_ id: Int, _ parent: Int, _ detail: String) -> ResultRow {
        ResultRow(id: id, values: [
            .int(Int64(id)), .int(Int64(parent)), .int(0), .string(detail),
        ])
    }

    @Test func sqliteQueryPlanTree() throws {
        let rows = [
            sqliteRow(3, 0, "SEARCH orders USING INDEX idx_user (user_id=?)"),
            sqliteRow(5, 0, "SCAN users"),
            sqliteRow(8, 5, "USE TEMP B-TREE FOR ORDER BY"),
        ]
        let plan = try ExplainPlanParser.parse(
            dialect: .sqlite, columns: sqliteColumns, rows: rows, isAnalyze: false)

        // Two top-level entries get a synthetic root.
        #expect(plan.root.operation == "Query Plan")
        #expect(plan.root.children.count == 2)

        let search = plan.root.children[0]
        #expect(search.operation == "SEARCH")
        #expect(search.relation == "orders")
        #expect(search.indexName == "idx_user")
        #expect(!search.isFullScan)

        let scan = plan.root.children[1]
        #expect(scan.operation == "SCAN")
        #expect(scan.relation == "users")
        #expect(scan.isFullScan)
        #expect(scan.children.count == 1)
        #expect(scan.children[0].operation == "USE TEMP B-TREE FOR ORDER BY")
        // No cost data anywhere: bars have no denominator.
        #expect(plan.totalCost == nil)
        #expect(scan.costShare(in: plan) == nil)
    }

    @Test func sqliteLegacyTableWording() throws {
        let rows = [sqliteRow(2, 0, "SCAN TABLE users")]
        let plan = try ExplainPlanParser.parse(
            dialect: .sqlite, columns: sqliteColumns, rows: rows, isAnalyze: false)
        #expect(plan.root.operation == "SCAN")
        #expect(plan.root.relation == "users")
    }

    // MARK: MongoDB

    @Test func mongoFindWithExecutionStats() throws {
        let reply = DBValue.fromJSONText("""
            {
              "ok": 1,
              "queryPlanner": {
                "namespace": "shop.orders",
                "winningPlan": {
                  "stage": "FETCH",
                  "inputStage": {"stage": "IXSCAN", "indexName": "user_id_1"}
                }
              },
              "executionStats": {
                "executionTimeMillis": 42,
                "executionStages": {
                  "stage": "FETCH",
                  "nReturned": 120,
                  "executionTimeMillisEstimate": 40,
                  "docsExamined": 120,
                  "inputStage": {
                    "stage": "IXSCAN",
                    "indexName": "user_id_1",
                    "nReturned": 120,
                    "executionTimeMillisEstimate": 5
                  }
                }
              }
            }
            """)!
        let plan = try ExplainPlanParser.parseMongo(reply: reply, isAnalyze: true)

        #expect(plan.executionTimeMs == 42)
        #expect(plan.root.operation == "FETCH")
        #expect(plan.root.relation == "shop.orders")
        #expect(plan.root.actualRows == 120)
        #expect(plan.root.properties.contains { $0.0 == "docsExamined" })
        let ixscan = try #require(plan.root.children.first)
        #expect(ixscan.operation == "IXSCAN")
        #expect(ixscan.indexName == "user_id_1")
    }

    @Test func mongoPlannerOnlyCollscanWarns() throws {
        let reply = DBValue.fromJSONText("""
            {
              "queryPlanner": {
                "namespace": "shop.orders",
                "winningPlan": {
                  "stage": "COLLSCAN",
                  "filter": {"status": {"$eq": "open"}},
                  "direction": "forward"
                }
              }
            }
            """)!
        let plan = try ExplainPlanParser.parseMongo(reply: reply, isAnalyze: false)
        #expect(plan.root.operation == "COLLSCAN")
        #expect(plan.root.isFullScan)
        #expect(plan.root.detail?.contains("filter:") == true)
        #expect(plan.root.warnings(in: plan).contains { $0.contains("Full scan") })
    }

    @Test func mongoAggregatePipelineStages() throws {
        let reply = DBValue.fromJSONText("""
            {
              "stages": [
                {"$cursor": {
                  "queryPlanner": {
                    "namespace": "shop.orders",
                    "winningPlan": {"stage": "COLLSCAN"}
                  }
                }},
                {"$group": {"_id": "$userId"}}
              ]
            }
            """)!
        let plan = try ExplainPlanParser.parseMongo(reply: reply, isAnalyze: false)
        #expect(plan.root.operation == "Aggregation Pipeline")
        #expect(plan.root.children.count == 2)
        #expect(plan.root.children[0].operation == "COLLSCAN")
        #expect(plan.root.children[1].operation == "$group")
    }

    @Test func mongoUnrecognizedShapeThrows() {
        #expect(throws: DBError.self) {
            try ExplainPlanParser.parseMongo(
                reply: .document(["nope": .int(1)]), isAnalyze: false)
        }
    }
}
