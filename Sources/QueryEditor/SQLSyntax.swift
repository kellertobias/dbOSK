import Foundation

/// Shared SQL vocabulary for the highlighter and the completion engine.
public enum SQLSyntax {
    public static let keywords = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE",
        "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "FULL", "CROSS", "ON", "AS", "GROUP", "BY",
        "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
        "CASE", "WHEN", "THEN", "ELSE", "END", "LIKE", "ILIKE", "BETWEEN",
        "EXISTS", "ASC", "DESC", "WITH", "RECURSIVE", "RETURNING", "CAST",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "TRUE", "FALSE",
    ]

    private static let keywordSet = Set(keywords)

    public static func isKeyword(_ word: String) -> Bool {
        keywordSet.contains(word.uppercased())
    }

    /// True when `identifier` cannot appear bare in SQL: it is empty, collides
    /// with a keyword, or contains characters outside `[A-Za-z0-9_]` (or
    /// starts with a digit).
    public static func needsQuoting(_ identifier: String) -> Bool {
        guard let first = identifier.utf8.first else { return true }
        guard first == UInt8(ascii: "_")
            || (first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z"))
            || (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z"))
        else { return true }
        for byte in identifier.utf8.dropFirst() {
            let ok = byte == UInt8(ascii: "_")
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            if !ok { return true }
        }
        return isKeyword(identifier)
    }
}
