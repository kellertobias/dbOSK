import Foundation
import Testing

@testable import DBCore

@Suite struct MutationStatementBuilderTests {
    private let postgres = DriverDescriptor(
        id: "postgres", displayName: "PostgreSQL", queryLanguage: .sql,
        defaultPort: 5432, supportsStreaming: true, supportsServerSideCancel: true,
        sqlDialect: .postgres, supportsTableEditing: true, supportsDDL: true)
    private let mysql = DriverDescriptor(
        id: "mysql", displayName: "MySQL", queryLanguage: .sql,
        defaultPort: 3306, supportsStreaming: true, supportsServerSideCancel: true,
        identifierQuote: "`", sqlDialect: .mysql, supportsTableEditing: true, supportsDDL: true)
    private let mongo = DriverDescriptor(
        id: "mongodb", displayName: "MongoDB", queryLanguage: .mongo,
        defaultPort: 27017, supportsStreaming: true, supportsServerSideCancel: false,
        identifierQuote: "")

    private var table: Namespace {
        Namespace(path: ["public", "users"], kind: .table(.table), isExpandable: false)
    }

    @Test func insertBuildsColumnsAndLiterals() throws {
        let sql = try MutationStatementBuilder.insert(
            into: table, columns: ["name", "age", "active"],
            values: [.string("O'Brien"), .int(30), .bool(true)],
            for: postgres)
        #expect(sql == #"INSERT INTO "public"."users" ("name", "age", "active") VALUES ('O''Brien', 30, TRUE)"#)
    }

    @Test func insertRequiresMatchingCounts() {
        #expect(throws: DBError.self) {
            try MutationStatementBuilder.insert(
                into: table, columns: ["a"], values: [], for: postgres)
        }
        #expect(throws: DBError.self) {
            try MutationStatementBuilder.insert(
                into: table, columns: [], values: [], for: postgres)
        }
    }

    @Test func updateTargetsKeys() throws {
        let sql = try MutationStatementBuilder.update(
            table,
            set: [.init(column: "name", value: .string("x"))],
            matching: [.init(column: "id", value: .int(7))],
            for: postgres)
        #expect(sql == #"UPDATE "public"."users" SET "name" = 'x' WHERE "id" = 7"#)
    }

    @Test func nullKeyUsesIsNull() throws {
        let sql = try MutationStatementBuilder.delete(
            from: table,
            matching: [
                .init(column: "id", value: .int(7)),
                .init(column: "tenant", value: .null),
            ],
            for: postgres)
        #expect(sql == #"DELETE FROM "public"."users" WHERE "id" = 7 AND "tenant" IS NULL"#)
    }

    @Test func refusesUnboundedStatements() {
        #expect(throws: DBError.self) {
            try MutationStatementBuilder.delete(from: table, matching: [], for: postgres)
        }
        #expect(throws: DBError.self) {
            try MutationStatementBuilder.update(
                table, set: [.init(column: "a", value: .int(1))], matching: [], for: postgres)
        }
        #expect(throws: DBError.self) {
            try MutationStatementBuilder.update(
                table, set: [], matching: [.init(column: "id", value: .int(1))], for: postgres)
        }
    }

    @Test func mysqlUsesBackticksAndEscaping() throws {
        let order = Namespace(path: ["shop", "order"], kind: .table(.table), isExpandable: false)
        let sql = try MutationStatementBuilder.update(
            order,
            set: [.init(column: "note", value: .string(#"a\b"#))],
            matching: [.init(column: "id", value: .int(1))],
            for: mysql)
        #expect(sql == #"UPDATE `shop`.`order` SET `note` = 'a\\b' WHERE `id` = 1"#)
    }

    @Test func nonSQLDriverThrowsUnsupported() {
        #expect(throws: DBError.self) {
            try MutationStatementBuilder.delete(
                from: table, matching: [.init(column: "id", value: .int(1))], for: mongo)
        }
    }
}
