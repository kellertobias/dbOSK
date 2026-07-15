import Foundation
import Testing

@testable import DBCore

@Suite struct ReadOnlySQLGateTests {

    private func accepts(
        _ sql: String, _ dialect: SQLDialect = .postgres,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: Never.self, "expected accept: \(sql)", sourceLocation: sourceLocation) {
            try ReadOnlySQLGate.validate(sql, dialect: dialect)
        }
    }

    private func rejects(
        _ sql: String, _ dialect: SQLDialect = .postgres,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            throws: ReadOnlySQLGate.Violation.self, "expected reject: \(sql)",
            sourceLocation: sourceLocation
        ) {
            try ReadOnlySQLGate.validate(sql, dialect: dialect)
        }
    }

    // MARK: - Accepted statements

    @Test func plainSelects() {
        accepts("SELECT 1")
        accepts("select * from users")
        accepts("  \n\t SELECT id, name FROM public.users WHERE id = 3 ORDER BY name LIMIT 10")
        accepts("(SELECT 1) UNION ALL (SELECT 2)")
        accepts("SELECT count(*) FROM orders GROUP BY status HAVING count(*) > 2")
        accepts("SELECT a FROM t1 JOIN t2 ON t1.id = t2.id LEFT JOIN t3 USING (id)")
    }

    @Test func trailingSemicolonsAndComments() {
        accepts("SELECT 1;")
        accepts("SELECT 1 ;  ")
        accepts("SELECT 1;;")
        accepts("SELECT 1; -- done")
        accepts("-- leading comment\nSELECT 1")
        accepts("/* block */ SELECT 1 /* trailing */;")
        accepts("SELECT 1 # trailing", .mysql)
    }

    @Test func ctesOfPureSelects() {
        accepts("WITH a AS (SELECT 1), b AS (SELECT * FROM a) SELECT * FROM b")
        accepts("WITH RECURSIVE r AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT * FROM r LIMIT 5")
    }

    @Test func writeKeywordsInsideQuotingAreInert() {
        accepts("SELECT 'DROP TABLE users'")
        accepts("SELECT 'DELETE FROM t; --'")
        accepts(#"SELECT "delete" FROM audit"#)
        accepts("SELECT `update` FROM audit", .mysql)
        accepts("SELECT $$INSERT INTO t VALUES (1)$$")
        accepts("SELECT $body$TRUNCATE x; DROP y$body$")
        accepts("SELECT 'it''s; DELETE FROM t'")
        accepts("SELECT E'a\\'; DROP TABLE t; --'")
    }

    @Test func caseEndAndIndexHints() {
        // END must stay allowed: every CASE expression uses it.
        accepts("SELECT CASE WHEN x > 0 THEN 'pos' ELSE 'neg' END FROM t")
        accepts("SELECT * FROM t USE INDEX (idx_a) WHERE a = 1", .mysql)
    }

    @Test func explainAndShowAndTable() {
        accepts("EXPLAIN SELECT * FROM t")
        accepts("EXPLAIN (FORMAT JSON) SELECT 1")
        accepts("EXPLAIN QUERY PLAN SELECT * FROM t", .sqlite)
        accepts("SHOW server_version")
        accepts("SHOW TABLES", .mysql)
        accepts("TABLE users")
    }

    @Test func parametersAndOperators() {
        accepts("SELECT * FROM t WHERE id = $1 AND x @> $2")
        accepts("SELECT * FROM t WHERE id = ? AND b = ?", .sqlite)
        accepts("SELECT data->>'key', x::text FROM t")
    }

    // MARK: - Rejected statements

    @Test func writeStatements() {
        rejects("INSERT INTO t VALUES (1)")
        rejects("UPDATE t SET a = 1")
        rejects("DELETE FROM t")
        rejects("delete from t where id = 1")
        rejects("TRUNCATE t")
        rejects("DROP TABLE t")
        rejects("ALTER TABLE t ADD COLUMN x int")
        rejects("CREATE TABLE t (id int)")
        rejects("GRANT ALL ON t TO joe")
        rejects("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DO NOTHING")
        rejects("REPLACE INTO t VALUES (1)", .mysql)
        rejects("COPY t TO '/tmp/out.csv'")
        rejects("CALL some_proc()")
        rejects("DO $$ BEGIN DELETE FROM t; END $$")
        rejects("VACUUM")
        rejects("PRAGMA journal_mode = DELETE", .sqlite)
    }

    @Test func writesSmuggledMidStatement() {
        rejects("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d")
        rejects("WITH x AS (INSERT INTO t VALUES (1) RETURNING id) SELECT * FROM x")
        rejects("WITH u AS (UPDATE t SET a = 1 RETURNING *) SELECT count(*) FROM u")
        rejects("SELECT * INTO backup FROM t")
        rejects("SELECT a FROM t INTO OUTFILE '/tmp/x'", .mysql)
    }

    @Test func multipleStatements() {
        rejects("SELECT 1; DELETE FROM t")
        rejects("SELECT 1; SELECT 2")
        rejects("SELECT 1;\n-- ok\nSELECT 2")
        rejects(";")
        rejects("")
        rejects("   -- only a comment")
    }

    @Test func sessionAndTransactionControl() {
        rejects("SET search_path TO public")
        rejects("SET SESSION transaction_read_only = 0", .mysql)
        rejects("BEGIN")
        rejects("COMMIT")
        rejects("ROLLBACK; SELECT 1")
        rejects("USE otherdb", .mysql)
        rejects("ATTACH DATABASE '/tmp/x.db' AS other", .sqlite)
        rejects("LISTEN chan")
        rejects("PREPARE s AS SELECT 1")
        rejects("EXECUTE s")
    }

    @Test func explainAnalyzeExecutesTheQuery() {
        rejects("EXPLAIN ANALYZE SELECT * FROM t")
        rejects("EXPLAIN (ANALYZE, BUFFERS) DELETE FROM t")
        rejects("EXPLAIN ANALYZE UPDATE t SET a = 1")
        rejects("ANALYZE t")
        rejects("ANALYSE t")
    }

    @Test func rowLockingClauses() {
        rejects("SELECT * FROM t FOR UPDATE")
        rejects("SELECT * FROM t FOR SHARE")
        rejects("SELECT * FROM t FOR NO KEY UPDATE")
        rejects("SELECT * FROM t FOR KEY SHARE")
        rejects("SELECT * FROM t LOCK IN SHARE MODE", .mysql)
    }

    @Test func unterminatedTokensNeverPass() {
        rejects("SELECT 'unterminated")
        rejects("SELECT \"unterminated")
        rejects("SELECT /* unterminated")
        rejects("SELECT $tag$ unterminated")
        rejects("SELECT `unterminated", .mysql)
    }

    @Test func mysqlExecutableCommentsRejected() {
        // MySQL runs /*! … */ bodies as SQL; never inert.
        rejects("SELECT 1 /*! ; DELETE FROM t */", .mysql)
        rejects("/*!50000 DELETE FROM t */", .mysql)
        // Plain block comments stay fine.
        accepts("SELECT 1 /* normal */", .mysql)
    }

    @Test func commentNestingMatchesEngine() {
        // Postgres nests block comments: the whole thing is one comment.
        accepts("/* outer /* inner */ still comment */ SELECT 1", .postgres)
        // MySQL/SQLite end the comment at the first */ — the tail would be
        // live SQL, so the gate must see (and reject) what follows.
        rejects("/* outer /* inner */ DELETE FROM t; -- */", .mysql)
        rejects("/* outer /* inner */ DELETE FROM t; -- */", .sqlite)
    }

    @Test func backslashEscapesMatchEngine() {
        // MySQL: backslash escapes the quote, string stays open → the DELETE
        // is inside the literal for the server, and the gate agrees.
        accepts(#"SELECT '\'; DELETE FROM t; --'"#, .mysql)
        // Postgres (standard_conforming_strings=on): '\' is a complete
        // literal, so the DELETE is live SQL → must reject.
        rejects(#"SELECT '\'; DELETE FROM t; --'"#, .postgres)
    }

    @Test func disallowedLeadingKeywords() {
        rejects("TABLE users", .mysql)      // TABLE is Postgres-only sugar
        rejects("SHOW TABLES", .sqlite)
        rejects("HANDLER t OPEN", .mysql)
        rejects("LOAD DATA INFILE 'x' INTO TABLE t", .mysql)
    }

    @Test func keywordNamedIdentifiersFailClosedWithGuidance() {
        do {
            try ReadOnlySQLGate.validate("SELECT update FROM audit", dialect: .postgres)
            Issue.record("expected rejection")
        } catch let violation as ReadOnlySQLGate.Violation {
            #expect(violation.reason.contains("quote"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Relation extraction

    private func relations(
        _ sql: String, _ dialect: SQLDialect = .postgres
    ) throws -> [[String]] {
        try ReadOnlySQLGate.referencedRelations(sql, dialect: dialect).map(\.path)
    }

    @Test func extractsFromAndJoins() throws {
        #expect(try relations("SELECT * FROM users") == [["users"]])
        #expect(try relations("SELECT * FROM public.users") == [["public", "users"]])
        #expect(
            try relations("SELECT * FROM a JOIN b ON a.id = b.id LEFT JOIN c.d ON true")
                == [["a"], ["b"], ["c", "d"]])
        #expect(
            try relations("SELECT * FROM a x, b y WHERE x.id = y.id")
                == [["a"], ["b"]])
    }

    @Test func extractsQuotedAndMixedPaths() throws {
        #expect(
            try relations(#"SELECT * FROM "Weird Schema"."My Table""#)
                == [["Weird Schema", "My Table"]])
        #expect(
            try relations("SELECT * FROM `db`.`tbl`", .mysql) == [["db", "tbl"]])
    }

    @Test func excludesCTEsFunctionsAndSubqueries() throws {
        #expect(
            try relations("WITH a AS (SELECT * FROM real_table) SELECT * FROM a")
                == [["real_table"]])
        #expect(try relations("SELECT * FROM generate_series(1, 10)") == [])
        #expect(
            try relations("SELECT * FROM (SELECT * FROM inner_table) sub")
                == [["inner_table"]])
    }

    @Test func extractsPostgresTableStatement() throws {
        #expect(try relations("TABLE public.users") == [["public", "users"]])
    }

    @Test func deduplicatesRepeatedRelations() throws {
        #expect(
            try relations("SELECT * FROM t JOIN t t2 ON t.id = t2.id") == [["t"]])
    }
}
