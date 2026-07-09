import Foundation

/// Column definition as entered in DDL sheets; maps onto `ColumnDetail` for
/// display, but `typeName` and `defaultExpression` are raw user-entered SQL.
public struct ColumnDefinition: Sendable, Hashable {
    public var name: String
    public var typeName: String
    public var isNullable: Bool
    /// Raw SQL expression (already dialect-appropriate), not a value literal.
    public var defaultExpression: String?
    public var isPrimaryKey: Bool

    public init(
        name: String, typeName: String, isNullable: Bool = true,
        defaultExpression: String? = nil, isPrimaryKey: Bool = false
    ) {
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
        self.defaultExpression = defaultExpression
        self.isPrimaryKey = isPrimaryKey
    }
}

public enum DDLValidationError: Error, Equatable, CustomStringConvertible {
    case noColumns
    case emptyColumnName
    case emptyTypeName(column: String)
    case emptyIndexName
    case noIndexColumns
    case sqliteAddColumnPrimaryKey
    case sqliteAddColumnNotNullNeedsDefault

    public var description: String {
        switch self {
        case .noColumns:
            return "A table needs at least one column"
        case .emptyColumnName:
            return "Column name must not be empty"
        case .emptyTypeName(let column):
            return "Column \"\(column)\" needs a type"
        case .emptyIndexName:
            return "Index name must not be empty"
        case .noIndexColumns:
            return "An index needs at least one column"
        case .sqliteAddColumnPrimaryKey:
            return "SQLite cannot add a PRIMARY KEY column to an existing table"
        case .sqliteAddColumnNotNullNeedsDefault:
            return "SQLite requires a default value when adding a NOT NULL column"
        }
    }
}

/// Builds dialect-correct DDL statements. No ALTER of column type/nullability
/// anywhere (sidesteps SQLite's biggest ALTER TABLE gap).
public enum DDLStatementBuilder {
    // MARK: Tables

    public static func createTable(
        _ table: Namespace, columns: [ColumnDefinition],
        for descriptor: DriverDescriptor
    ) throws -> String {
        let dialect = try descriptor.requireSQLDialect()
        guard !columns.isEmpty else { throw DDLValidationError.noColumns }
        try validate(columns)

        let primaryKeys = columns.filter(\.isPrimaryKey)
        // Single SQLite INTEGER PK stays inline so it becomes a rowid alias
        // (autoincrementing); everything else uses a table-level constraint.
        let inlinePrimaryKey = dialect == .sqlite && primaryKeys.count == 1
            && primaryKeys[0].typeName.uppercased() == "INTEGER"

        var clauses = try columns.map {
            try columnClause($0, inlinePrimaryKey: inlinePrimaryKey, descriptor: descriptor)
        }
        if !primaryKeys.isEmpty, !inlinePrimaryKey {
            let keyList = primaryKeys.map { descriptor.quoted($0.name) }.joined(separator: ", ")
            clauses.append("PRIMARY KEY (\(keyList))")
        }
        return "CREATE TABLE \(descriptor.qualified(table)) (\n  "
            + clauses.joined(separator: ",\n  ") + "\n)"
    }

    public static func dropTable(_ table: Namespace, for descriptor: DriverDescriptor) -> String {
        "DROP TABLE \(descriptor.qualified(table))"
    }

    // MARK: Columns

    public static func addColumn(
        _ column: ColumnDefinition, to table: Namespace,
        for descriptor: DriverDescriptor
    ) throws -> String {
        let dialect = try descriptor.requireSQLDialect()
        try validate([column])
        if dialect == .sqlite {
            if column.isPrimaryKey { throw DDLValidationError.sqliteAddColumnPrimaryKey }
            if !column.isNullable, emptied(column.defaultExpression) == nil {
                throw DDLValidationError.sqliteAddColumnNotNullNeedsDefault
            }
        }
        let clause = try columnClause(column, inlinePrimaryKey: false, descriptor: descriptor)
        var sql = "ALTER TABLE \(descriptor.qualified(table)) ADD COLUMN \(clause)"
        if column.isPrimaryKey, dialect != .sqlite {
            sql += " PRIMARY KEY"
        }
        return sql
    }

    public static func dropColumn(
        _ name: String, from table: Namespace, for descriptor: DriverDescriptor
    ) -> String {
        "ALTER TABLE \(descriptor.qualified(table)) DROP COLUMN \(descriptor.quoted(name))"
    }

    public static func renameColumn(
        _ name: String, to newName: String, in table: Namespace,
        for descriptor: DriverDescriptor
    ) -> String {
        "ALTER TABLE \(descriptor.qualified(table)) RENAME COLUMN "
            + "\(descriptor.quoted(name)) TO \(descriptor.quoted(newName))"
    }

    // MARK: Indexes

    public static func createIndex(
        named name: String, on table: Namespace, columns: [String], unique: Bool,
        for descriptor: DriverDescriptor
    ) throws -> String {
        _ = try descriptor.requireSQLDialect()
        guard emptied(name) != nil else { throw DDLValidationError.emptyIndexName }
        guard !columns.isEmpty else { throw DDLValidationError.noIndexColumns }
        let columnList = columns.map { descriptor.quoted($0) }.joined(separator: ", ")
        let kind = unique ? "UNIQUE INDEX" : "INDEX"
        return "CREATE \(kind) \(descriptor.quoted(name)) ON \(descriptor.qualified(table)) (\(columnList))"
    }

    public static func dropIndex(
        named name: String, on table: Namespace, for descriptor: DriverDescriptor
    ) throws -> String {
        switch try descriptor.requireSQLDialect() {
        case .mysql:
            // MySQL scopes indexes to their table.
            return "DROP INDEX \(descriptor.quoted(name)) ON \(descriptor.qualified(table))"
        case .postgres:
            // Indexes live in the table's schema; qualify so this works
            // regardless of search_path.
            let qualified = (table.path.dropLast() + [name])
                .map { descriptor.quoted($0) }
                .joined(separator: ".")
            return "DROP INDEX \(qualified)"
        case .sqlite:
            return "DROP INDEX \(descriptor.quoted(name))"
        }
    }

    // MARK: Helpers

    private static func columnClause(
        _ column: ColumnDefinition, inlinePrimaryKey: Bool, descriptor: DriverDescriptor
    ) throws -> String {
        var clause = "\(descriptor.quoted(column.name)) \(column.typeName)"
        if inlinePrimaryKey, column.isPrimaryKey {
            clause += " PRIMARY KEY"
        }
        if !column.isNullable {
            clause += " NOT NULL"
        }
        if let defaultExpression = emptied(column.defaultExpression) {
            clause += " DEFAULT \(defaultExpression)"
        }
        return clause
    }

    private static func validate(_ columns: [ColumnDefinition]) throws {
        for column in columns {
            guard emptied(column.name) != nil else { throw DDLValidationError.emptyColumnName }
            guard emptied(column.typeName) != nil else {
                throw DDLValidationError.emptyTypeName(column: column.name)
            }
        }
    }

    private static func emptied(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
