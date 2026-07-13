import Foundation

/// Wraps a user query in the dialect's EXPLAIN statement. Mirrors
/// `SQLLiteralEncoder`: pure string building, unit-testable in DBCore.
public enum ExplainStatementBuilder {
    public static func statement(
        for sql: String, dialect: SQLDialect, analyze: Bool
    ) -> String {
        let query = trimmed(sql)
        switch dialect {
        case .postgres:
            return analyze
                ? "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) \(query)"
                : "EXPLAIN (FORMAT JSON) \(query)"
        case .mysql:
            return "EXPLAIN FORMAT=JSON \(query)"
        case .sqlite:
            return "EXPLAIN QUERY PLAN \(query)"
        }
    }

    /// True when the statement is a plain read (safe to ANALYZE without
    /// side effects): SELECT, WITH, VALUES, TABLE.
    public static func isReadOnlyStatement(_ sql: String) -> Bool {
        var query = trimmed(sql)
        while query.hasPrefix("(") { query.removeFirst() }
        let firstWord = query.split(whereSeparator: \.isWhitespace)
            .first.map { $0.uppercased() } ?? ""
        return ["SELECT", "WITH", "VALUES", "TABLE"].contains(firstWord)
    }

    /// Strips whitespace and a trailing semicolon (EXPLAIN wraps a single
    /// statement; a trailing `;` is fine but a bare one after stripping
    /// comments is not).
    private static func trimmed(_ sql: String) -> String {
        var query = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while query.hasSuffix(";") {
            query.removeLast()
            query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return query
    }
}
