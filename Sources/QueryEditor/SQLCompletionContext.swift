import Foundation

// MARK: - Public context types

/// What the completion popup should offer at a cursor position.
public struct CompletionContext: Equatable {
    public enum Kind: Equatable {
        /// Plain identifier position: columns of referenced tables, tables,
        /// keywords all apply.
        case identifier(prefix: String)
        /// Directly after FROM/JOIN/INTO/UPDATE/TABLE: table names.
        case tableName(prefix: String)
        /// After a dotted qualifier (`u.`, `public.users.`): members of it.
        case memberAccess(qualifier: [String], prefix: String)
    }

    public let kind: Kind
    /// The UTF-16 range the committed suggestion replaces (the typed prefix,
    /// including an unterminated opening quote when present).
    public let replacementRange: NSRange

    public init(kind: Kind, replacementRange: NSRange) {
        self.kind = kind
        self.replacementRange = replacementRange
    }
}

/// A table mentioned in FROM/JOIN/UPDATE/INTO, with its alias if any.
public struct TableReference: Equatable, Sendable {
    /// Dotted name parts as written, unquoted (e.g. ["public", "users"]).
    public let path: [String]
    public let alias: String?

    public init(path: [String], alias: String?) {
        self.path = path
        self.alias = alias
    }
}

// MARK: - Tokenizer

/// One lexical token with its UTF-16 range. Hand-rolled scanner rather than
/// regex: completion needs string/comment awareness, quoted-identifier inner
/// text, and exact ranges — and must never mis-lex on unterminated input.
struct SQLToken {
    enum Kind: Equatable {
        /// `name` is the unquoted spelling. `terminated` is false for an
        /// open quoted identifier still being typed (`"us`).
        case identifier(name: String, quoted: Bool, terminated: Bool)
        case dot
        case comma
        case lparen
        case string(terminated: Bool)
        case comment(terminated: Bool)
        case number
        case punctuation
    }

    let kind: Kind
    let range: NSRange
}

enum SQLTokenizer {
    static func tokenize(_ text: String) -> [SQLToken] {
        let units = Array(text.utf16)
        var tokens: [SQLToken] = []
        var i = 0

        func unit(_ ascii: Character) -> UInt16 { ascii.utf16.first! }
        let quote = unit("\""), backtick = unit("`"), apostrophe = unit("'")
        let dash = unit("-"), slash = unit("/"), star = unit("*")
        let newline = unit("\n"), underscore = unit("_"), dot = unit(".")

        func isDigit(_ u: UInt16) -> Bool { u >= unit("0") && u <= unit("9") }
        func isIdentStart(_ u: UInt16) -> Bool {
            u == underscore || (u >= unit("A") && u <= unit("Z"))
                || (u >= unit("a") && u <= unit("z")) || u > 127
        }
        func isIdentChar(_ u: UInt16) -> Bool { isIdentStart(u) || isDigit(u) }
        func string(from start: Int, to end: Int) -> String {
            String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
        }

        while i < units.count {
            let u = units[i]
            let start = i

            // Whitespace
            if u == unit(" ") || u == unit("\t") || u == newline || u == unit("\r") {
                i += 1
                continue
            }

            // Line comment
            if u == dash, i + 1 < units.count, units[i + 1] == dash {
                while i < units.count, units[i] != newline { i += 1 }
                tokens.append(SQLToken(
                    kind: .comment(terminated: i < units.count),
                    range: NSRange(location: start, length: i - start)))
                continue
            }

            // Block comment
            if u == slash, i + 1 < units.count, units[i + 1] == star {
                i += 2
                var terminated = false
                while i < units.count {
                    if units[i] == star, i + 1 < units.count, units[i + 1] == slash {
                        i += 2
                        terminated = true
                        break
                    }
                    i += 1
                }
                tokens.append(SQLToken(
                    kind: .comment(terminated: terminated),
                    range: NSRange(location: start, length: i - start)))
                continue
            }

            // String literal ('' escapes)
            if u == apostrophe {
                i += 1
                var terminated = false
                while i < units.count {
                    if units[i] == apostrophe {
                        if i + 1 < units.count, units[i + 1] == apostrophe {
                            i += 2
                            continue
                        }
                        i += 1
                        terminated = true
                        break
                    }
                    i += 1
                }
                tokens.append(SQLToken(
                    kind: .string(terminated: terminated),
                    range: NSRange(location: start, length: i - start)))
                continue
            }

            // Quoted identifier ("..." or `...`, doubled-quote escapes)
            if u == quote || u == backtick {
                let closer = u
                i += 1
                var inner: [UInt16] = []
                var terminated = false
                while i < units.count {
                    if units[i] == closer {
                        if i + 1 < units.count, units[i + 1] == closer {
                            inner.append(closer)
                            i += 2
                            continue
                        }
                        i += 1
                        terminated = true
                        break
                    }
                    inner.append(units[i])
                    i += 1
                }
                tokens.append(SQLToken(
                    kind: .identifier(
                        name: String(utf16CodeUnits: inner, count: inner.count),
                        quoted: true, terminated: terminated),
                    range: NSRange(location: start, length: i - start)))
                continue
            }

            // Number (digits, optional fraction/exponent chars)
            if isDigit(u) {
                while i < units.count, isDigit(units[i]) || isIdentChar(units[i]) {
                    i += 1
                }
                if i < units.count, units[i] == dot, i + 1 < units.count,
                   isDigit(units[i + 1]) {
                    i += 1
                    while i < units.count, isDigit(units[i]) { i += 1 }
                }
                tokens.append(SQLToken(
                    kind: .number,
                    range: NSRange(location: start, length: i - start)))
                continue
            }

            // Bare identifier / keyword
            if isIdentStart(u) {
                while i < units.count, isIdentChar(units[i]) { i += 1 }
                tokens.append(SQLToken(
                    kind: .identifier(
                        name: string(from: start, to: i),
                        quoted: false, terminated: true),
                    range: NSRange(location: start, length: i - start)))
                continue
            }

            // Single-character tokens
            i += 1
            let kind: SQLToken.Kind
            switch u {
            case dot: kind = .dot
            case unit(","): kind = .comma
            case unit("("): kind = .lparen
            default: kind = .punctuation
            }
            tokens.append(SQLToken(kind: kind, range: NSRange(location: start, length: 1)))
        }

        return tokens
    }
}

// MARK: - Analyzer

public enum SQLContextAnalyzer {
    /// The completion context at `cursorUTF16`, or nil when the cursor is
    /// inside a string literal, a comment, or a closed quoted identifier.
    public static func context(in text: String, cursorUTF16 cursor: Int)
        -> CompletionContext?
    {
        let tokens = SQLTokenizer.tokenize(text)

        // Suppress inside strings/comments. Unterminated ones swallow
        // everything to the end of the text.
        for token in tokens {
            let end = token.range.location + token.range.length
            switch token.kind {
            case .string(let terminated), .comment(let terminated):
                let inside = terminated
                    ? cursor > token.range.location && cursor < end
                    : cursor > token.range.location
                if inside { return nil }
            default:
                break
            }
        }

        // The identifier token being typed, if the cursor touches one.
        var prefix = ""
        var replacementRange = NSRange(location: cursor, length: 0)
        var chainIndex = tokens.count  // index of the token before the qualifier walk
        if let index = tokens.firstIndex(where: { token in
            let end = token.range.location + token.range.length
            guard case .identifier = token.kind else { return false }
            return token.range.location < cursor && cursor <= end
        }) {
            guard case .identifier(let name, let quoted, let terminated) =
                tokens[index].kind else { return nil }
            if quoted {
                // Only an open quote counts as a typed prefix; a closed
                // quoted identifier is complete — nothing to offer.
                guard !terminated,
                      cursor == tokens[index].range.location + tokens[index].range.length
                else { return nil }
                prefix = name
            } else {
                let nsText = text as NSString
                prefix = nsText.substring(
                    with: NSRange(
                        location: tokens[index].range.location,
                        length: cursor - tokens[index].range.location))
            }
            replacementRange = NSRange(
                location: tokens[index].range.location,
                length: cursor - tokens[index].range.location)
            chainIndex = index
        } else {
            chainIndex = tokens.firstIndex {
                $0.range.location + $0.range.length > cursor
            } ?? tokens.count
        }

        // Walk backwards over `identifier . identifier . …` to collect the
        // dotted qualifier.
        var qualifier: [String] = []
        var i = chainIndex - 1
        while i >= 1, case .dot = tokens[i].kind,
              case .identifier(let name, _, let terminated) = tokens[i - 1].kind,
              terminated
        {
            qualifier.insert(name, at: 0)
            i -= 2
        }

        if !qualifier.isEmpty {
            return CompletionContext(
                kind: .memberAccess(qualifier: qualifier, prefix: prefix),
                replacementRange: replacementRange)
        }

        // Preceding significant token decides table-name position.
        var previous = chainIndex - 1
        while previous >= 0, case .comment = tokens[previous].kind { previous -= 1 }
        if previous >= 0,
           case .identifier(let word, false, _) = tokens[previous].kind,
           ["FROM", "JOIN", "INTO", "UPDATE", "TABLE"].contains(word.uppercased())
        {
            return CompletionContext(
                kind: .tableName(prefix: prefix), replacementRange: replacementRange)
        }

        return CompletionContext(
            kind: .identifier(prefix: prefix), replacementRange: replacementRange)
    }

    /// Tables mentioned after FROM/JOIN/UPDATE/INTO, with aliases. FROM
    /// supports comma-separated lists; subqueries (`FROM (`) are skipped.
    public static func referencedTables(in text: String) -> [TableReference] {
        let tokens = SQLTokenizer.tokenize(text).filter {
            if case .comment = $0.kind { return false }
            return true
        }
        var references: [TableReference] = []
        var i = 0

        func parseReference(at start: Int) -> (TableReference, Int)? {
            var j = start
            var path: [String] = []
            while j < tokens.count,
                  case .identifier(let name, let quoted, true) = tokens[j].kind,
                  quoted || !SQLSyntax.isKeyword(name)
            {
                path.append(name)
                j += 1
                guard j < tokens.count, case .dot = tokens[j].kind else { break }
                j += 1
            }
            guard !path.isEmpty else { return nil }
            // A function call, not a table.
            if j < tokens.count, case .lparen = tokens[j].kind { return nil }

            var alias: String?
            if j < tokens.count,
               case .identifier(let word, false, _) = tokens[j].kind,
               word.uppercased() == "AS"
            {
                j += 1
            }
            if j < tokens.count,
               case .identifier(let name, let quoted, true) = tokens[j].kind,
               quoted || !SQLSyntax.isKeyword(name)
            {
                alias = name
                j += 1
            }
            return (TableReference(path: path, alias: alias), j)
        }

        while i < tokens.count {
            defer { i += 1 }
            guard case .identifier(let word, false, _) = tokens[i].kind else { continue }
            let keyword = word.uppercased()
            guard ["FROM", "JOIN", "UPDATE", "INTO"].contains(keyword) else { continue }

            var next = i + 1
            while let (reference, after) = parseReference(at: next) {
                references.append(reference)
                // Comma-separated lists only make sense after FROM.
                guard keyword == "FROM", after < tokens.count,
                      case .comma = tokens[after].kind
                else {
                    next = after
                    break
                }
                next = after + 1
            }
            i = max(i, next - 1)
        }

        return references
    }
}
