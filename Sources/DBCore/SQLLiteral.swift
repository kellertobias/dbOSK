import Foundation

/// SQL dialect for generated DML/DDL statements and value literals.
public enum SQLDialect: String, Sendable, Hashable {
    case postgres, mysql, sqlite
}

/// Renders `DBValue`s as SQL literals. Generated statements embed literals
/// rather than bind parameters so the Apply preview shows exactly what runs
/// and the encoding stays unit-testable in DBCore.
public enum SQLLiteralEncoder {
    public static func literal(_ value: DBValue, dialect: SQLDialect) throws -> String {
        switch value {
        case .null:
            return "NULL"
        case .bool(let flag):
            switch dialect {
            case .sqlite: return flag ? "1" : "0"
            case .postgres, .mysql: return flag ? "TRUE" : "FALSE"
            }
        case .int(let int):
            return String(int)
        case .double(let double):
            guard double.isFinite else {
                throw DBError(kind: .unsupported, message: "Cannot encode non-finite number \(double)")
            }
            return String(double)
        case .decimal(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard isNumericLiteral(trimmed) else {
                throw DBError(kind: .unsupported, message: "Invalid numeric value: \(text)")
            }
            return trimmed
        case .string(let string):
            return quoted(string, dialect: dialect)
        case .date(let date):
            var iso = DBValue.isoString(date)
            // MySQL rejects the Z suffix in datetime literals.
            if dialect == .mysql, iso.hasSuffix("Z") { iso.removeLast() }
            return quoted(iso, dialect: dialect)
        case .uuid(let uuid):
            return quoted(uuid.uuidString.lowercased(), dialect: dialect)
        case .bytes(let data):
            let hex = data.map { String(format: "%02x", $0) }.joined()
            switch dialect {
            case .postgres: return "'\\x\(hex)'::bytea"
            case .mysql, .sqlite: return "X'\(hex)'"
            }
        case .document, .array:
            return quoted(value.jsonString(prettyPrinted: false), dialect: dialect)
        case .unsupported(let typeName, _):
            throw DBError(kind: .unsupported, message: "Cannot encode value of type \(typeName)")
        }
    }

    /// Escapes and single-quotes a string literal. MySQL additionally treats
    /// backslash as an escape character under the default sql_mode; servers
    /// running NO_BACKSLASH_ESCAPES would double backslashes (known caveat).
    static func quoted(_ string: String, dialect: SQLDialect) -> String {
        var escaped = string
        if dialect == .mysql {
            escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        }
        escaped = escaped.replacingOccurrences(of: "'", with: "''")
        return "'" + escaped + "'"
    }

    /// Plain numeric literal: optional sign, digits, fraction, exponent.
    /// Anything else must not be emitted raw into SQL.
    static func isNumericLiteral(_ text: String) -> Bool {
        text.wholeMatch(of: /[+-]?\d+(\.\d+)?([eE][+-]?\d+)?/) != nil
    }
}

extension DriverDescriptor {
    /// Fully quoted, dot-joined namespace path ("schema"."table").
    public func qualified(_ namespace: Namespace) -> String {
        namespace.path.map { quoted($0) }.joined(separator: ".")
    }

    func requireSQLDialect() throws -> SQLDialect {
        guard let sqlDialect else {
            throw DBError(
                kind: .unsupported,
                message: "\(displayName) does not support generated SQL statements")
        }
        return sqlDialect
    }
}
