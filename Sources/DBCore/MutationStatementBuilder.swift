import Foundation

/// Builds dialect-correct INSERT/UPDATE/DELETE statements for staged table
/// edits. Kept in DBCore (like `TableQueryBuilder`) so it is unit-testable.
public enum MutationStatementBuilder {
    /// Column/value pair; UPDATE assignments and WHERE key matches.
    public struct ColumnValue: Sendable {
        public let column: String
        public let value: DBValue

        public init(column: String, value: DBValue) {
            self.column = column
            self.value = value
        }
    }

    public static func insert(
        into table: Namespace, columns: [String], values: [DBValue],
        for descriptor: DriverDescriptor
    ) throws -> String {
        let dialect = try descriptor.requireSQLDialect()
        guard !columns.isEmpty, columns.count == values.count else {
            throw DBError(kind: .queryFailed, message: "Insert requires matching columns and values")
        }
        let columnList = columns.map { descriptor.quoted($0) }.joined(separator: ", ")
        let valueList = try values
            .map { try SQLLiteralEncoder.literal($0, dialect: dialect) }
            .joined(separator: ", ")
        return "INSERT INTO \(descriptor.qualified(table)) (\(columnList)) VALUES (\(valueList))"
    }

    public static func update(
        _ table: Namespace, set assignments: [ColumnValue], matching keys: [ColumnValue],
        for descriptor: DriverDescriptor
    ) throws -> String {
        let dialect = try descriptor.requireSQLDialect()
        guard !assignments.isEmpty else {
            throw DBError(kind: .queryFailed, message: "Update requires at least one assignment")
        }
        let setList = try assignments
            .map {
                "\(descriptor.quoted($0.column)) = \(try SQLLiteralEncoder.literal($0.value, dialect: dialect))"
            }
            .joined(separator: ", ")
        let condition = try whereClause(keys, dialect: dialect, descriptor: descriptor)
        return "UPDATE \(descriptor.qualified(table)) SET \(setList) WHERE \(condition)"
    }

    public static func delete(
        from table: Namespace, matching keys: [ColumnValue],
        for descriptor: DriverDescriptor
    ) throws -> String {
        let dialect = try descriptor.requireSQLDialect()
        let condition = try whereClause(keys, dialect: dialect, descriptor: descriptor)
        return "DELETE FROM \(descriptor.qualified(table)) WHERE \(condition)"
    }

    /// Key match by original values; refuses to build an unbounded statement.
    private static func whereClause(
        _ keys: [ColumnValue], dialect: SQLDialect, descriptor: DriverDescriptor
    ) throws -> String {
        guard !keys.isEmpty else {
            throw DBError(kind: .queryFailed, message: "Refusing to build a statement without key columns")
        }
        return try keys
            .map { key in
                if key.value.isNull {
                    return "\(descriptor.quoted(key.column)) IS NULL"
                }
                let literal = try SQLLiteralEncoder.literal(key.value, dialect: dialect)
                return "\(descriptor.quoted(key.column)) = \(literal)"
            }
            .joined(separator: " AND ")
    }
}
