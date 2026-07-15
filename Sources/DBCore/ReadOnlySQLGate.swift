import Foundation

/// Validates that a SQL statement is provably read-only before it runs on
/// behalf of an MCP client. Tokenizer-based, not a full parser: input that
/// cannot be tokenized, spans multiple statements, or contains a
/// write-capable keyword outside string/identifier quoting is rejected.
/// Unlike `ExplainStatementBuilder.isReadOnlyStatement` (a loose first-keyword
/// check for the Explain UI), this gate fails closed: a false rejection of an
/// unquoted identifier named like a keyword is the accepted tradeoff.
public enum ReadOnlySQLGate {

    public struct Violation: Error, Sendable, Equatable, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
        public init(reason: String) { self.reason = reason }
    }

    /// A table/view reference as written in the query, split into path
    /// components (e.g. `public.users` → ["public", "users"]).
    public struct RelationReference: Sendable, Hashable {
        public let path: [String]
        public init(path: [String]) { self.path = path }
    }

    /// Statements that may start a read-only query, per dialect.
    static func allowedLeadingKeywords(for dialect: SQLDialect) -> Set<String> {
        var allowed: Set<String> = ["SELECT", "WITH", "VALUES", "EXPLAIN"]
        switch dialect {
        case .postgres: allowed.formUnion(["TABLE", "SHOW"])
        case .mysql: allowed.insert("SHOW")
        case .sqlite: break
        }
        return allowed
    }

    /// Keywords that make a statement write-capable (or transaction/session
    /// altering) no matter where they appear outside quoting. Scanned over
    /// every word token, so `WITH d AS (DELETE …) SELECT …` and
    /// `SELECT … INTO t` are rejected even though they lead with an allowed
    /// keyword. `ANALYZE` covers `EXPLAIN ANALYZE`, which executes the query.
    static let deniedKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "REPLACE",
        "DROP", "ALTER", "CREATE", "RENAME", "COMMENT",
        "GRANT", "REVOKE", "SECURITY",
        "COPY", "CALL", "DO", "EXEC", "EXECUTE", "PREPARE", "DEALLOCATE",
        "VACUUM", "ANALYZE", "ANALYSE", "REINDEX", "CLUSTER", "REFRESH",
        "SET", "RESET", "DISCARD", "PRAGMA",
        "LOCK", "UNLOCK", "LISTEN", "UNLISTEN", "NOTIFY",
        "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE",
        "ATTACH", "DETACH", "INTO", "IMPORT", "LOAD", "HANDLER",
        "FLUSH", "KILL", "OPTIMIZE", "REPAIR", "PURGE", "CHANGE", "STOP",
        "INSTALL", "UNINSTALL", "SIGNAL", "RESIGNAL", "DECLARE",
        // `END` (CASE … END) and `USE` (MySQL index hints) are deliberately
        // absent: dangerous only statement-initially, where the leading
        // keyword allowlist already blocks them.
    ]

    /// Row-locking clauses: `FOR UPDATE` is caught by the deny list; the
    /// remaining `FOR SHARE` / `FOR KEY SHARE` / `FOR NO KEY UPDATE` variants
    /// are caught contextually so a column named `share` stays usable.
    static let deniedAfterFor: Set<String> = ["UPDATE", "SHARE", "NO", "KEY"]

    /// Throws unless `sql` is a single, provably read-only statement.
    public static func validate(_ sql: String, dialect: SQLDialect) throws {
        var tokenizer = SQLReadOnlyTokenizer(sql: sql, dialect: dialect)
        let tokens = try tokenizer.tokenize()
        let words = tokens.compactMap { token -> String? in
            if case .word(let text) = token { return text.uppercased() }
            return nil
        }

        // A statement may open with parentheses: `(SELECT 1) UNION (SELECT 2)`.
        let firstWordToken = tokens.first { $0 != .symbol("(") }
        guard case .word(let first)? = firstWordToken else {
            throw Violation(reason: "Empty statement. Provide a single read-only query.")
        }
        let leading = first.uppercased()
        guard allowedLeadingKeywords(for: dialect).contains(leading) else {
            throw Violation(reason:
                "Statement starts with '\(leading)', which is not an allowed read-only "
                + "statement. Allowed: \(allowedLeadingKeywords(for: dialect).sorted().joined(separator: ", ")).")
        }

        // Single statement only: a semicolon may only be followed by more
        // (redundant) semicolons.
        var seenSemicolon = false
        for token in tokens {
            if case .symbol(";") = token {
                seenSemicolon = true
            } else if seenSemicolon {
                throw Violation(reason:
                    "Multiple SQL statements are not allowed. Send one read-only statement per query.")
            }
        }

        var previousWord: String?
        for word in words {
            if deniedKeywords.contains(word) {
                throw Violation(reason:
                    "Statement contains the write-capable or session-altering keyword '\(word)'. "
                    + "Only read-only queries are allowed; if '\(word.lowercased())' is one of your "
                    + "identifiers, quote it.")
            }
            if previousWord == "FOR", deniedAfterFor.contains(word) {
                throw Violation(reason:
                    "Row-locking clause 'FOR \(word)…' is not allowed in read-only queries.")
            }
            previousWord = word
        }
    }

    /// The statement's first keyword (uppercased), ignoring comments and
    /// leading parentheses. Lets callers decide whether a plan-based
    /// allowlist check applies (SELECT/WITH/VALUES/TABLE read relations;
    /// SHOW/EXPLAIN do not).
    public static func leadingKeyword(_ sql: String, dialect: SQLDialect) throws -> String {
        var tokenizer = SQLReadOnlyTokenizer(sql: sql, dialect: dialect)
        let tokens = try tokenizer.tokenize()
        for token in tokens {
            if case .word(let word) = token { return word.uppercased() }
            if case .symbol("(") = token { continue }
            break
        }
        throw Violation(reason: "Empty statement. Provide a single read-only query.")
    }

    /// Best-effort extraction of the tables/views a statement reads, for
    /// allowlist checks. Finds relation paths after FROM/JOIN (and Postgres
    /// `TABLE`), skips function calls and derived tables, and excludes CTE
    /// names. Callers must back this up with an engine-plan check where
    /// available; it is an aid, not the sole enforcement.
    public static func referencedRelations(
        _ sql: String, dialect: SQLDialect
    ) throws -> [RelationReference] {
        var tokenizer = SQLReadOnlyTokenizer(sql: sql, dialect: dialect)
        let tokens = try tokenizer.tokenize()
        let cteNames = collectCTENames(tokens)
        var seen = Set<[String]>()
        var relations: [RelationReference] = []

        func record(_ path: [String]) {
            if path.count == 1, cteNames.contains(path[0].lowercased()) { return }
            guard seen.insert(path).inserted else { return }
            relations.append(RelationReference(path: path))
        }

        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            guard case .word(let word) = tokens[index] else { continue }
            let keyword = word.uppercased()
            let isLeadingTable = keyword == "TABLE" && index == 0 && dialect == .postgres
            guard keyword == "FROM" || keyword == "JOIN" || isLeadingTable else { continue }
            var cursor = index + 1
            scanRelationList(tokens, from: &cursor, record: record)
        }
        return relations
    }

    // MARK: - Relation scanning helpers

    /// Words that terminate a FROM item list (so `FROM a x, b y WHERE …`
    /// collects both `a` and `b` and stops at WHERE).
    private static let fromListTerminators: Set<String> = [
        "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR",
        "UNION", "INTERSECT", "EXCEPT", "WINDOW", "ON", "USING",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "LATERAL",
    ]

    private static func scanRelationList(
        _ tokens: [SQLReadOnlyToken], from index: inout Int,
        record: ([String]) -> Void
    ) {
        while index < tokens.count {
            // Skip modifiers that precede a relation name.
            while index < tokens.count, case .word(let word) = tokens[index],
                ["ONLY", "LATERAL"].contains(word.uppercased()) {
                index += 1
            }
            guard index < tokens.count else { return }

            switch tokens[index] {
            case .symbol("("):
                // Derived table / subquery: its own FROM is visited by the
                // outer token walk, so just balance past it here.
                skipBalancedParens(tokens, from: &index)
            case .word, .quoted:
                if let path = parseRelationPath(tokens, from: &index) {
                    // A name directly followed by '(' is a function call.
                    if index < tokens.count, case .symbol("(") = tokens[index] {
                        skipBalancedParens(tokens, from: &index)
                    } else {
                        record(path)
                    }
                }
            default:
                return
            }

            // Skip alias tokens until a comma continues the list or a clause
            // keyword / statement end terminates it.
            while index < tokens.count {
                switch tokens[index] {
                case .symbol(","):
                    index += 1
                    break
                case .symbol("("):
                    skipBalancedParens(tokens, from: &index)
                    continue
                case .symbol(")"), .symbol(";"):
                    return
                case .word(let word) where fromListTerminators.contains(word.uppercased()):
                    return
                default:
                    index += 1
                    continue
                }
                break
            }
            if index >= tokens.count { return }
        }
    }

    /// Parses `name(.name)*` starting at `index`; leaves `index` after it.
    private static func parseRelationPath(
        _ tokens: [SQLReadOnlyToken], from index: inout Int
    ) -> [String]? {
        var path: [String] = []
        while index < tokens.count {
            switch tokens[index] {
            case .word(let text): path.append(text)
            case .quoted(let text): path.append(text)
            default: return path.isEmpty ? nil : path
            }
            index += 1
            guard index < tokens.count, case .symbol(".") = tokens[index] else { break }
            index += 1
        }
        return path.isEmpty ? nil : path
    }

    private static func skipBalancedParens(
        _ tokens: [SQLReadOnlyToken], from index: inout Int
    ) {
        guard index < tokens.count, case .symbol("(") = tokens[index] else { return }
        var depth = 0
        while index < tokens.count {
            if case .symbol("(") = tokens[index] { depth += 1 }
            if case .symbol(")") = tokens[index] {
                depth -= 1
                if depth == 0 { index += 1; return }
            }
            index += 1
        }
    }

    /// Names bound by `<name> [(columns)] AS (` — CTEs (and named windows,
    /// which are not relations either), excluded from relation references.
    private static func collectCTENames(_ tokens: [SQLReadOnlyToken]) -> Set<String> {
        var names = Set<String>()
        for (index, token) in tokens.enumerated() {
            let name: String
            switch token {
            case .word(let text): name = text
            case .quoted(let text): name = text
            default: continue
            }
            var cursor = index + 1
            if cursor < tokens.count, case .symbol("(") = tokens[cursor] {
                skipBalancedParens(tokens, from: &cursor)
            }
            guard cursor + 1 < tokens.count,
                case .word(let asWord) = tokens[cursor], asWord.uppercased() == "AS",
                case .symbol("(") = tokens[cursor + 1]
            else { continue }
            names.insert(name.lowercased())
        }
        return names
    }
}

// MARK: - Tokenizer

enum SQLReadOnlyToken: Equatable {
    /// Unquoted word: keyword or identifier, as written.
    case word(String)
    /// Quoted identifier, unescaped content.
    case quoted(String)
    /// String literal; content is irrelevant to the gate.
    case string
    case number
    case symbol(Character)
}

/// Dialect-aware tokenizer that errs toward rejection: comment and string
/// rules follow what each engine actually executes (MySQL `/*!…*/` executable
/// comments are rejected outright, block comments nest only on Postgres,
/// backslash escapes strings only on MySQL), so the gate can never classify
/// text as inert that the server would run.
struct SQLReadOnlyTokenizer {
    private let chars: [Character]
    private let dialect: SQLDialect
    private var index = 0

    init(sql: String, dialect: SQLDialect) {
        self.chars = Array(sql)
        self.dialect = dialect
    }

    private var current: Character? { index < chars.count ? chars[index] : nil }
    private func peek(_ offset: Int = 1) -> Character? {
        let target = index + offset
        return target < chars.count ? chars[target] : nil
    }

    mutating func tokenize() throws -> [SQLReadOnlyToken] {
        var tokens: [SQLReadOnlyToken] = []
        while let char = current {
            if char.isWhitespace {
                index += 1
            } else if char == "-", peek() == "-" {
                skipLineComment()
            } else if char == "#", dialect == .mysql {
                skipLineComment()
            } else if char == "/", peek() == "*" {
                try skipBlockComment()
            } else if char == "'" {
                try scanSingleQuotedString(backslashEscapes: dialect == .mysql)
                tokens.append(.string)
            } else if char == "\"" {
                if dialect == .mysql {
                    // Default sql_mode: double quotes delimit strings. Parsed
                    // with '""' doubling only — no backslash — so the token
                    // boundary is safe under ANSI_QUOTES servers too.
                    try scanQuoted(terminator: "\"", backslashEscapes: false)
                    tokens.append(.string)
                } else {
                    let content = try scanQuoted(terminator: "\"", backslashEscapes: false)
                    tokens.append(.quoted(content))
                }
            } else if char == "`", dialect == .mysql {
                let content = try scanQuoted(terminator: "`", backslashEscapes: false)
                tokens.append(.quoted(content))
            } else if char == "$", dialect == .postgres {
                try tokens.append(scanDollar())
            } else if char.isNumber {
                scanNumber()
                tokens.append(.number)
            } else if isWordStart(char) {
                let word = scanWord()
                // Postgres escape/byte/bit/national string prefixes: E'…'
                // honors backslash escapes; treat all as opaque strings.
                if current == "'", word.count == 1,
                    "EeBbXxNn".contains(word) {
                    let escapes = dialect == .mysql
                        || (dialect == .postgres && word.lowercased() == "e")
                    try scanSingleQuotedString(backslashEscapes: escapes)
                    tokens.append(.string)
                } else {
                    tokens.append(.word(word))
                }
            } else {
                tokens.append(.symbol(char))
                index += 1
            }
        }
        return tokens
    }

    private func isWordStart(_ char: Character) -> Bool {
        char.isLetter || char == "_"
    }

    private func isWordContinuation(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_" || char == "$"
    }

    private mutating func scanWord() -> String {
        var word = ""
        while let char = current, isWordContinuation(char) {
            word.append(char)
            index += 1
        }
        return word
    }

    private mutating func scanNumber() {
        // Loose numeric scan (digits, hex, exponent); content is irrelevant,
        // it only needs to not be mistaken for a word.
        while let char = current, char.isNumber || char.isLetter || char == "." {
            index += 1
        }
    }

    private mutating func skipLineComment() {
        while let char = current, char != "\n" { index += 1 }
    }

    private mutating func skipBlockComment() throws {
        // MySQL executes `/*!…*/` (version-gated) comment bodies as SQL —
        // never inert, so reject outright.
        if dialect == .mysql, peek(2) == "!" {
            throw ReadOnlySQLGate.Violation(reason:
                "MySQL executable comments (/*! … */) are not allowed.")
        }
        index += 2
        var depth = 1
        while index < chars.count {
            if chars[index] == "/", peek() == "*", dialect == .postgres {
                // Only Postgres nests block comments; MySQL and SQLite end at
                // the first `*/`, so treating them as nested would hide live
                // SQL from the scan.
                depth += 1
                index += 2
            } else if chars[index] == "*", peek() == "/" {
                depth -= 1
                index += 2
                if depth == 0 { return }
            } else {
                index += 1
            }
        }
        throw ReadOnlySQLGate.Violation(reason: "Unterminated block comment.")
    }

    private mutating func scanSingleQuotedString(backslashEscapes: Bool) throws {
        index += 1  // opening quote
        while index < chars.count {
            let char = chars[index]
            if char == "\\", backslashEscapes {
                index += 2
            } else if char == "'" {
                if peek() == "'" {
                    index += 2  // doubled quote stays inside the string
                } else {
                    index += 1
                    return
                }
            } else {
                index += 1
            }
        }
        throw ReadOnlySQLGate.Violation(reason: "Unterminated string literal.")
    }

    @discardableResult
    private mutating func scanQuoted(
        terminator: Character, backslashEscapes: Bool
    ) throws -> String {
        index += 1  // opening quote
        var content = ""
        while index < chars.count {
            let char = chars[index]
            if char == "\\", backslashEscapes {
                if let escaped = peek() { content.append(escaped) }
                index += 2
            } else if char == terminator {
                if peek() == terminator {
                    content.append(terminator)
                    index += 2
                } else {
                    index += 1
                    return content
                }
            } else {
                content.append(char)
                index += 1
            }
        }
        throw ReadOnlySQLGate.Violation(reason:
            "Unterminated quoted identifier or string.")
    }

    /// `$1` positional parameter or `$tag$…$tag$` dollar-quoted string.
    private mutating func scanDollar() throws -> SQLReadOnlyToken {
        if let next = peek(), next.isNumber {
            index += 1
            while let char = current, char.isNumber { index += 1 }
            return .number
        }
        // Scan the opening tag: $ [identifier]? $
        var cursor = index + 1
        var tag = ""
        while cursor < chars.count, chars[cursor].isLetter || chars[cursor].isNumber || chars[cursor] == "_" {
            tag.append(chars[cursor])
            cursor += 1
        }
        guard cursor < chars.count, chars[cursor] == "$" else {
            throw ReadOnlySQLGate.Violation(reason:
                "Unrecognized '$' sequence; only $n parameters and $tag$…$tag$ quoting are allowed.")
        }
        let delimiter = "$\(tag)$"
        index = cursor + 1
        // Find the closing delimiter.
        let delimiterChars = Array(delimiter)
        while index < chars.count {
            if chars[index] == "$", matches(delimiterChars, at: index) {
                index += delimiterChars.count
                return .string
            }
            index += 1
        }
        throw ReadOnlySQLGate.Violation(reason: "Unterminated dollar-quoted string.")
    }

    private func matches(_ pattern: [Character], at start: Int) -> Bool {
        guard start + pattern.count <= chars.count else { return false }
        for (offset, char) in pattern.enumerated()
        where chars[start + offset] != char {
            return false
        }
        return true
    }
}
