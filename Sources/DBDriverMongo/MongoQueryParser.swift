import DBCore
import Foundation

/// Parsed form of a mongo-shell-style query string, e.g.
/// `db.users.find({"status": "active"}).skip(10).limit(50)`.
struct MongoShellQuery: Equatable {
    var collection: String
    var operation: MongoOperation
    /// JSON body: a filter document for find/count, a pipeline array for aggregate.
    var body: String
    var skip: Int?
    var limit: Int?
}

enum MongoQueryParser {
    /// Accepts `db.<collection>.<find|aggregate|count>(<json>)` with optional
    /// `.skip(n)` / `.limit(n)` suffixes. Whitespace and a trailing `;` are fine.
    static func parse(_ text: String) throws -> MongoShellQuery {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasSuffix(";") { input = String(input.dropLast()) }

        let pattern = #"^db\.([A-Za-z0-9_.\-]+)\.(find|aggregate|count)\s*\("#
        guard let match = input.range(of: pattern, options: .regularExpression) else {
            throw DBError(
                kind: .queryFailed,
                message: """
                Could not parse query. Expected: db.<collection>.find({...}), \
                db.<collection>.aggregate([...]) or db.<collection>.count({...}), \
                optionally followed by .skip(n) and .limit(n)
                """)
        }

        let header = String(input[match])
        // header = "db.<collection>.<op>(" — split out the middle parts.
        let inner = header.dropFirst(3).dropLast()  // strip "db." and "("
        let segments = inner.split(separator: ".")
        let opName = segments.last!.trimmingCharacters(in: .whitespaces)
        let collection = segments.dropLast().joined(separator: ".")
        guard let operation = MongoOperation(rawValue: opName) else {
            throw DBError(kind: .queryFailed, message: "Unsupported operation: \(opName)")
        }

        // Find the matching closing parenthesis for the body.
        let bodyStart = match.upperBound
        var depth = 1
        var index = bodyStart
        var inString = false
        var previous: Character = " "
        while index < input.endIndex {
            let char = input[index]
            if inString {
                if char == "\"" && previous != "\\" { inString = false }
            } else {
                switch char {
                case "\"": inString = true
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
            }
            if depth == 0 { break }
            previous = char
            index = input.index(after: index)
        }
        guard depth == 0 else {
            throw DBError(kind: .queryFailed, message: "Unbalanced parentheses in query")
        }

        var body = String(input[bodyStart..<index])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            body = operation == .aggregate ? "[]" : "{}"
        }

        var query = MongoShellQuery(
            collection: collection, operation: operation, body: body)

        // Optional .skip(n) / .limit(n) suffixes.
        let rest = String(input[input.index(after: index)...])
        for (name, value) in modifiers(in: rest) {
            switch name {
            case "skip": query.skip = value
            case "limit": query.limit = value
            default:
                throw DBError(kind: .queryFailed, message: "Unsupported modifier: .\(name)()")
            }
        }
        return query
    }

    private static func modifiers(in text: String) -> [(String, Int)] {
        let pattern = #"\.([a-zA-Z]+)\s*\(\s*(\d+)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text),
                  let value = Int(text[valueRange])
            else { return nil }
            return (String(text[nameRange]), value)
        }
    }
}
