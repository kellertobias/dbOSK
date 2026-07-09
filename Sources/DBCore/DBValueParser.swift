import Foundation

/// Converts editor text back into a `DBValue`, guided by the column's declared
/// type. Deliberately conservative: only unambiguous mappings (integers,
/// floats, decimals, booleans) are parsed client-side; everything else passes
/// through as a string literal and the server casts.
public enum DBValueParser {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case invalidInteger(String)
        case invalidNumber(String)
        case invalidDecimal(String)
        case invalidBool(String)
        case binaryNotEditable

        public var description: String {
            switch self {
            case .invalidInteger(let text): return "Not a valid integer: \(text)"
            case .invalidNumber(let text): return "Not a valid number: \(text)"
            case .invalidDecimal(let text): return "Not a valid decimal: \(text)"
            case .invalidBool(let text): return "Not a valid boolean: \(text)"
            case .binaryNotEditable: return "Binary values cannot be edited"
            }
        }
    }

    /// `text == nil` is the editor's explicit NULL sentinel — NULL is never
    /// inferred from typed text (an empty string in a text column stays "").
    public static func parse(_ text: String?, dbTypeName: String) throws -> DBValue {
        guard let text else { return .null }

        switch classify(dbTypeName) {
        case .integer:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let int = Int64(trimmed) else { throw ParseError.invalidInteger(text) }
            return .int(int)
        case .float:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let double = Double(trimmed), double.isFinite else {
                throw ParseError.invalidNumber(text)
            }
            return .double(double)
        case .decimal:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard SQLLiteralEncoder.isNumericLiteral(trimmed) else {
                throw ParseError.invalidDecimal(text)
            }
            return .decimal(trimmed)
        case .boolean:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "t", "1", "yes": return .bool(true)
            case "false", "f", "0", "no": return .bool(false)
            default: throw ParseError.invalidBool(text)
            }
        case .binary:
            throw ParseError.binaryNotEditable
        case .other:
            return .string(text)
        }
    }

    private enum TypeClass {
        case integer, float, decimal, boolean, binary, other
    }

    private static let integerTokens: Set<String> = [
        "int", "integer", "int2", "int4", "int8", "bigint", "smallint",
        "tinyint", "mediumint", "serial", "bigserial", "smallserial",
    ]
    private static let floatTokens: Set<String> = [
        "real", "float", "float4", "float8", "double",
    ]
    private static let decimalTokens: Set<String> = ["numeric", "decimal", "dec"]
    private static let booleanTokens: Set<String> = ["bool", "boolean"]
    private static let binaryTokens: Set<String> = [
        "bytea", "blob", "binary", "varbinary", "tinyblob", "mediumblob", "longblob",
    ]

    /// Token-based matching (not substring) so e.g. Postgres "point" doesn't
    /// classify as an integer type.
    private static func classify(_ dbTypeName: String) -> TypeClass {
        let tokens = dbTypeName.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        for token in tokens {
            if integerTokens.contains(token) { return .integer }
            if floatTokens.contains(token) { return .float }
            if decimalTokens.contains(token) { return .decimal }
            if booleanTokens.contains(token) { return .boolean }
            if binaryTokens.contains(token) { return .binary }
        }
        return .other
    }
}
