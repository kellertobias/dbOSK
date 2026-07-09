import Foundation
import Testing

@testable import DBCore

@Suite struct DDLStatementBuilderTests {
    private let postgres = DriverDescriptor(
        id: "postgres", displayName: "PostgreSQL", queryLanguage: .sql,
        defaultPort: 5432, supportsStreaming: true, supportsServerSideCancel: true,
        sqlDialect: .postgres, supportsTableEditing: true, supportsDDL: true)
    private let mysql = DriverDescriptor(
        id: "mysql", displayName: "MySQL", queryLanguage: .sql,
        defaultPort: 3306, supportsStreaming: true, supportsServerSideCancel: true,
        identifierQuote: "`", sqlDialect: .mysql, supportsTableEditing: true, supportsDDL: true)
    private let sqlite = DriverDescriptor(
        id: "sqlite", displayName: "SQLite", queryLanguage: .sql,
        defaultPort: nil, supportsStreaming: true, supportsServerSideCancel: true,
        sqlDialect: .sqlite, supportsTableEditing: true, supportsDDL: true)

    private var table: Namespace {
        Namespace(path: ["public", "users"], kind: .table(.table), isExpandable: false)
    }
    private var sqliteTable: Namespace {
        Namespace(path: ["users"], kind: .table(.table), isExpandable: false)
    }

    // MARK: Create table

    @Test func createTableWithTableLevelPrimaryKey() throws {
        let sql = try DDLStatementBuilder.createTable(
            table,
            columns: [
                ColumnDefinition(name: "id", typeName: "bigint", isNullable: false, isPrimaryKey: true),
                ColumnDefinition(name: "name", typeName: "text", isNullable: false),
                ColumnDefinition(name: "status", typeName: "text", defaultExpression: "'open'"),
            ],
            for: postgres)
        #expect(sql == """
            CREATE TABLE "public"."users" (
              "id" bigint NOT NULL,
              "name" text NOT NULL,
              "status" text DEFAULT 'open',
              PRIMARY KEY ("id")
            )
            """)
    }

    @Test func sqliteSingleIntegerPrimaryKeyStaysInline() throws {
        // Inline INTEGER PRIMARY KEY = rowid alias (autoincrement semantics).
        let sql = try DDLStatementBuilder.createTable(
            sqliteTable,
            columns: [
                ColumnDefinition(name: "id", typeName: "INTEGER", isPrimaryKey: true),
                ColumnDefinition(name: "name", typeName: "TEXT"),
            ],
            for: sqlite)
        #expect(sql == """
            CREATE TABLE "users" (
              "id" INTEGER PRIMARY KEY,
              "name" TEXT
            )
            """)
    }

    @Test func sqliteCompositePrimaryKeyIsTableLevel() throws {
        let sql = try DDLStatementBuilder.createTable(
            sqliteTable,
            columns: [
                ColumnDefinition(name: "a", typeName: "INTEGER", isPrimaryKey: true),
                ColumnDefinition(name: "b", typeName: "TEXT", isPrimaryKey: true),
            ],
            for: sqlite)
        #expect(sql.contains(#"PRIMARY KEY ("a", "b")"#))
        #expect(!sql.contains(#""a" INTEGER PRIMARY KEY"#))
    }

    @Test func createTableValidation() {
        #expect(throws: DDLValidationError.noColumns) {
            try DDLStatementBuilder.createTable(table, columns: [], for: postgres)
        }
        #expect(throws: DDLValidationError.emptyColumnName) {
            try DDLStatementBuilder.createTable(
                table, columns: [ColumnDefinition(name: " ", typeName: "text")], for: postgres)
        }
        #expect(throws: DDLValidationError.emptyTypeName(column: "x")) {
            try DDLStatementBuilder.createTable(
                table, columns: [ColumnDefinition(name: "x", typeName: "")], for: postgres)
        }
    }

    // MARK: Alter table

    @Test func addColumn() throws {
        let sql = try DDLStatementBuilder.addColumn(
            ColumnDefinition(name: "age", typeName: "integer", isNullable: false, defaultExpression: "0"),
            to: table, for: postgres)
        #expect(sql == #"ALTER TABLE "public"."users" ADD COLUMN "age" integer NOT NULL DEFAULT 0"#)
    }

    @Test func sqliteAddColumnRestrictions() throws {
        #expect(throws: DDLValidationError.sqliteAddColumnPrimaryKey) {
            try DDLStatementBuilder.addColumn(
                ColumnDefinition(name: "id2", typeName: "INTEGER", isPrimaryKey: true),
                to: sqliteTable, for: sqlite)
        }
        #expect(throws: DDLValidationError.sqliteAddColumnNotNullNeedsDefault) {
            try DDLStatementBuilder.addColumn(
                ColumnDefinition(name: "x", typeName: "TEXT", isNullable: false),
                to: sqliteTable, for: sqlite)
        }
        // With a default it is allowed.
        let sql = try DDLStatementBuilder.addColumn(
            ColumnDefinition(name: "x", typeName: "TEXT", isNullable: false, defaultExpression: "''"),
            to: sqliteTable, for: sqlite)
        #expect(sql == #"ALTER TABLE "users" ADD COLUMN "x" TEXT NOT NULL DEFAULT ''"#)
    }

    @Test func dropAndRenameColumn() throws {
        #expect(DDLStatementBuilder.dropColumn("age", from: table, for: postgres)
            == #"ALTER TABLE "public"."users" DROP COLUMN "age""#)
        #expect(DDLStatementBuilder.renameColumn("age", to: "years", in: table, for: mysql)
            == "ALTER TABLE `public`.`users` RENAME COLUMN `age` TO `years`")
    }

    @Test func dropTable() {
        #expect(DDLStatementBuilder.dropTable(table, for: postgres)
            == #"DROP TABLE "public"."users""#)
    }

    // MARK: Indexes

    @Test func createIndex() throws {
        let sql = try DDLStatementBuilder.createIndex(
            named: "idx_users_name", on: table, columns: ["name", "status"], unique: false,
            for: postgres)
        #expect(sql == #"CREATE INDEX "idx_users_name" ON "public"."users" ("name", "status")"#)

        let unique = try DDLStatementBuilder.createIndex(
            named: "uq_users_name", on: table, columns: ["name"], unique: true, for: postgres)
        #expect(unique == #"CREATE UNIQUE INDEX "uq_users_name" ON "public"."users" ("name")"#)
    }

    @Test func createIndexValidation() {
        #expect(throws: DDLValidationError.emptyIndexName) {
            try DDLStatementBuilder.createIndex(
                named: " ", on: table, columns: ["a"], unique: false, for: postgres)
        }
        #expect(throws: DDLValidationError.noIndexColumns) {
            try DDLStatementBuilder.createIndex(
                named: "idx", on: table, columns: [], unique: false, for: postgres)
        }
    }

    @Test func dropIndexPerDialect() throws {
        // Postgres: schema-qualified so it works regardless of search_path.
        #expect(try DDLStatementBuilder.dropIndex(named: "idx_x", on: table, for: postgres)
            == #"DROP INDEX "public"."idx_x""#)
        // MySQL: index is scoped to its table.
        #expect(try DDLStatementBuilder.dropIndex(named: "idx_x", on: table, for: mysql)
            == "DROP INDEX `idx_x` ON `public`.`users`")
        // SQLite: single-level namespace.
        #expect(try DDLStatementBuilder.dropIndex(named: "idx_x", on: sqliteTable, for: sqlite)
            == #"DROP INDEX "idx_x""#)
    }
}
