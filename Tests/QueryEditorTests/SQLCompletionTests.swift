import DBCore
import Foundation
import Testing

@testable import QueryEditor

// MARK: - Helpers

/// Context at the `|` marker in `text` (the marker is removed first).
private func context(_ marked: String) -> CompletionContext? {
    let cursor = (marked as NSString).range(of: "|").location
    let text = marked.replacingOccurrences(of: "|", with: "")
    return SQLContextAnalyzer.context(in: text, cursorUTF16: cursor)
}

@Suite struct SQLSyntaxTests {
    @Test func needsQuotingTruthTable() {
        #expect(!SQLSyntax.needsQuoting("email"))
        #expect(!SQLSyntax.needsQuoting("user_id"))
        #expect(!SQLSyntax.needsQuoting("_hidden"))
        #expect(!SQLSyntax.needsQuoting("Table2"))
        #expect(SQLSyntax.needsQuoting("order"))  // keyword collision? no —
        // "ORDER" is a keyword, so it must be quoted.
        #expect(SQLSyntax.needsQuoting("SELECT"))
        #expect(SQLSyntax.needsQuoting("user name"))  // space
        #expect(SQLSyntax.needsQuoting("2fast"))  // leading digit
        #expect(SQLSyntax.needsQuoting("naïve"))  // non-ASCII
        #expect(SQLSyntax.needsQuoting(""))
    }

    @Test func keywordLookupIsCaseInsensitive() {
        #expect(SQLSyntax.isKeyword("select"))
        #expect(SQLSyntax.isKeyword("From"))
        #expect(!SQLSyntax.isKeyword("users"))
    }
}

@Suite struct SQLContextAnalyzerTests {
    @Test func plainIdentifierPrefix() {
        let ctx = context("SELECT na|")
        #expect(ctx?.kind == .identifier(prefix: "na"))
        #expect(ctx?.replacementRange == NSRange(location: 7, length: 2))
    }

    @Test func tableNameAfterFrom() {
        #expect(context("SELECT * FROM us|")?.kind == .tableName(prefix: "us"))
        #expect(context("select * from us|")?.kind == .tableName(prefix: "us"))
    }

    @Test func tableNameAfterJoinAndUpdate() {
        #expect(context("SELECT * FROM a JOIN or|")?.kind == .tableName(prefix: "or"))
        #expect(context("UPDATE us|")?.kind == .tableName(prefix: "us"))
        #expect(context("INSERT INTO us|")?.kind == .tableName(prefix: "us"))
    }

    @Test func memberAccessAfterDot() {
        let ctx = context("SELECT u.| FROM users u")
        #expect(ctx?.kind == .memberAccess(qualifier: ["u"], prefix: ""))
        #expect(ctx?.replacementRange == NSRange(location: 9, length: 0))
    }

    @Test func memberAccessWithPrefix() {
        #expect(context("SELECT u.na| FROM users u")?.kind
            == .memberAccess(qualifier: ["u"], prefix: "na"))
    }

    @Test func multiPartQualifier() {
        #expect(context("SELECT * FROM public.users WHERE public.users.i|")?.kind
            == .memberAccess(qualifier: ["public", "users"], prefix: "i"))
        #expect(context("SELECT * FROM public.|")?.kind
            == .memberAccess(qualifier: ["public"], prefix: ""))
    }

    @Test func quotedQualifier() {
        #expect(context(#"SELECT "Order Items".|"#)?.kind
            == .memberAccess(qualifier: ["Order Items"], prefix: ""))
    }

    @Test func openQuotePrefixIncludesQuoteInRange() {
        let ctx = context(#"SELECT * FROM "us|"#)
        #expect(ctx?.kind == .tableName(prefix: "us"))
        #expect(ctx?.replacementRange == NSRange(location: 14, length: 3))
    }

    @Test func nilInsideStringsAndComments() {
        #expect(context("SELECT 'na|me'") == nil)
        #expect(context("SELECT 'unterminated na|") == nil)
        #expect(context("SELECT 1 -- comment na|") == nil)
        #expect(context("SELECT /* block na| */ 1") == nil)
    }

    @Test func cursorMidIdentifierUsesLeftPartAsPrefix() {
        let ctx = context("SELECT na|me")
        #expect(ctx?.kind == .identifier(prefix: "na"))
        #expect(ctx?.replacementRange == NSRange(location: 7, length: 2))
    }

    @Test func emptyPrefixInOpenSpace() {
        #expect(context("SELECT |")?.kind == .identifier(prefix: ""))
        #expect(context("SELECT * FROM |")?.kind == .tableName(prefix: ""))
    }
}

@Suite struct ReferencedTablesTests {
    private func refs(_ sql: String) -> [TableReference] {
        SQLContextAnalyzer.referencedTables(in: sql)
    }

    @Test func commaSeparatedFromList() {
        #expect(refs("SELECT * FROM a, b") == [
            TableReference(path: ["a"], alias: nil),
            TableReference(path: ["b"], alias: nil),
        ])
    }

    @Test func joinWithAsAlias() {
        #expect(refs("SELECT * FROM users u JOIN orders AS o ON u.id = o.uid") == [
            TableReference(path: ["users"], alias: "u"),
            TableReference(path: ["orders"], alias: "o"),
        ])
    }

    @Test func schemaQualifiedJoinWithBareAlias() {
        #expect(refs("SELECT * FROM t LEFT JOIN sch.other x ON 1=1") == [
            TableReference(path: ["t"], alias: nil),
            TableReference(path: ["sch", "other"], alias: "x"),
        ])
    }

    @Test func keywordAfterTableIsNotAnAlias() {
        #expect(refs("SELECT * FROM users WHERE id = 1") == [
            TableReference(path: ["users"], alias: nil)
        ])
        #expect(refs("UPDATE users SET name = 'x'") == [
            TableReference(path: ["users"], alias: nil)
        ])
    }

    @Test func quotedTableNames() {
        #expect(refs(#"SELECT * FROM "Order Items" oi"#) == [
            TableReference(path: ["Order Items"], alias: "oi")
        ])
    }

    @Test func multiStatementText() {
        #expect(refs("SELECT * FROM a; INSERT INTO b VALUES (1)") == [
            TableReference(path: ["a"], alias: nil),
            TableReference(path: ["b"], alias: nil),
        ])
    }

    @Test func functionCallIsNotATable() {
        #expect(refs("SELECT * FROM generate_series(1, 10)").isEmpty)
    }

    @Test func commentsAreIgnored() {
        #expect(refs("SELECT * FROM /* x */ users") == [
            TableReference(path: ["users"], alias: nil)
        ])
    }
}

@Suite struct CompletionEngineTests {
    private let schema = SchemaSnapshot(
        tables: [
            .init(path: ["main", "users"]),
            .init(path: ["main", "orders"]),
            .init(path: ["main", "order"]),
            .init(path: ["analytics", "events"]),
        ],
        containers: [["main"], ["analytics"]],
        columns: [
            SchemaSnapshot.key(["main", "users"]): [
                ColumnMeta(name: "id", dbTypeName: "integer"),
                ColumnMeta(name: "name", dbTypeName: "text"),
                ColumnMeta(name: "email", dbTypeName: "text"),
            ],
            SchemaSnapshot.key(["main", "order"]): [
                ColumnMeta(name: "total", dbTypeName: "numeric")
            ],
        ])

    private let engine = CompletionEngine(identifierQuote: "\"")

    private func complete(_ marked: String, explicit: Bool = false) -> CompletionResult? {
        let cursor = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        return engine.complete(
            text: text, cursorUTF16: cursor, schema: schema, explicit: explicit)
    }

    @Test func referencedColumnsRankAboveTables() {
        let result = complete("SELECT e| FROM users")
        let labels = result?.items.map(\.label) ?? []
        // "email" (column of the referenced table) before "events" (table).
        #expect(labels.first == "email")
        #expect(labels.contains("events"))
        #expect(result?.items.first?.kind == .column)
    }

    @Test func aliasResolvesToColumns() {
        let result = complete("SELECT u.| FROM users u")
        #expect(result?.items.map(\.label) == ["email", "id", "name"])
        #expect(result?.items.allSatisfy { $0.kind == .column } == true)
    }

    @Test func tableNameQualifierResolvesToColumns() {
        let result = complete("SELECT users.na| FROM users")
        #expect(result?.items.map(\.label) == ["name"])
    }

    @Test func schemaQualifierListsItsTables() {
        let result = complete("SELECT * FROM main.|")
        #expect(result?.items.map(\.label) == ["order", "orders", "users"])
        #expect(result?.items.allSatisfy { $0.kind == .table } == true)
    }

    @Test func schemaTableQualifierResolvesColumns() {
        let result = complete("SELECT main.users.| FROM main.users")
        #expect(result?.items.map(\.label) == ["email", "id", "name"])
    }

    @Test func missingColumnsAreReported() {
        let result = complete("SELECT * FROM events e WHERE e.|")
        #expect(result?.items.isEmpty == true)
        #expect(result?.missingColumnTables == [["analytics", "events"]])
    }

    @Test func keywordCollisionIsQuoted() {
        let result = complete("SELECT * FROM ord|")
        let order = result?.items.first { $0.label == "order" }
        #expect(order?.insertText == "\"order\"")
        let orders = result?.items.first { $0.label == "orders" }
        #expect(orders?.insertText == "orders")
    }

    @Test func backtickDialectQuoting() {
        let mysql = CompletionEngine(identifierQuote: "`")
        let result = mysql.complete(
            text: "SELECT * FROM ord", cursorUTF16: 17, schema: schema,
            explicit: false)
        #expect(result?.items.first { $0.label == "order" }?.insertText == "`order`")
    }

    @Test func keywordsOnlyAtTwoCharPrefix() {
        let short = complete("SELECT x FROM t WHERE s|")
        #expect(short?.items.contains { $0.kind == .keyword } != true)
        let longer = complete("SELECT x FROM t WHERE se|")
        #expect(longer?.items.contains { $0.label == "SELECT" } == true)
    }

    @Test func emptyPrefixRequiresExplicit() {
        #expect(complete("SELECT |") == nil)
        let explicit = complete("SELECT | FROM users", explicit: true)
        #expect(explicit?.items.isEmpty == false)
        #expect(explicit?.items.first?.kind == .column)
    }

    @Test func dotAlwaysTriggersWithoutExplicit() {
        #expect(complete("SELECT u.| FROM users u") != nil)
    }

    @Test func noPopupInsideString() {
        #expect(complete("SELECT 'use|r'") == nil)
    }

    @Test func openQuoteCommitReplacesTheQuote() {
        let result = complete(#"SELECT * FROM "ord|"#)
        #expect(result?.replacementRange == NSRange(location: 14, length: 4))
        #expect(result?.items.first { $0.label == "order" } != nil)
    }

    @Test func matchingIsCaseInsensitiveButInsertsExactSpelling() {
        let result = complete("SELECT * FROM USER|")
        #expect(result?.items.first?.label == "users")
        #expect(result?.items.first?.insertText == "users")
    }
}
