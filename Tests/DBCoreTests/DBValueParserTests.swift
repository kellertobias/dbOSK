import Foundation
import Testing

@testable import DBCore

@Suite struct DBValueParserTests {
    @Test func nilSentinelIsNull() throws {
        #expect(try DBValueParser.parse(nil, dbTypeName: "text") == .null)
        #expect(try DBValueParser.parse(nil, dbTypeName: "integer") == .null)
    }

    @Test func emptyStringStaysEmptyString() throws {
        // NULL is never inferred from typed text.
        #expect(try DBValueParser.parse("", dbTypeName: "text") == .string(""))
    }

    @Test func integers() throws {
        #expect(try DBValueParser.parse(" 42 ", dbTypeName: "integer") == .int(42))
        #expect(try DBValueParser.parse("-7", dbTypeName: "BIGINT") == .int(-7))
        #expect(try DBValueParser.parse("9", dbTypeName: "int unsigned") == .int(9))
        #expect(try DBValueParser.parse("3", dbTypeName: "int8") == .int(3))
        #expect(throws: DBValueParser.ParseError.invalidInteger("abc")) {
            try DBValueParser.parse("abc", dbTypeName: "integer")
        }
        #expect(throws: DBValueParser.ParseError.invalidInteger("")) {
            try DBValueParser.parse("", dbTypeName: "integer")
        }
    }

    @Test func floatsAndDecimals() throws {
        #expect(try DBValueParser.parse("1.5", dbTypeName: "double precision") == .double(1.5))
        #expect(try DBValueParser.parse("2", dbTypeName: "REAL") == .double(2))
        #expect(try DBValueParser.parse("12.34", dbTypeName: "numeric(10,2)") == .decimal("12.34"))
        #expect(throws: DBValueParser.ParseError.invalidNumber("x")) {
            try DBValueParser.parse("x", dbTypeName: "float8")
        }
        #expect(throws: DBValueParser.ParseError.invalidDecimal("1,5")) {
            try DBValueParser.parse("1,5", dbTypeName: "decimal")
        }
    }

    @Test func booleans() throws {
        #expect(try DBValueParser.parse("true", dbTypeName: "boolean") == .bool(true))
        #expect(try DBValueParser.parse("F", dbTypeName: "bool") == .bool(false))
        #expect(try DBValueParser.parse("1", dbTypeName: "boolean") == .bool(true))
        #expect(throws: DBValueParser.ParseError.invalidBool("maybe")) {
            try DBValueParser.parse("maybe", dbTypeName: "boolean")
        }
    }

    @Test func binaryRejected() {
        #expect(throws: DBValueParser.ParseError.binaryNotEditable) {
            try DBValueParser.parse("0102", dbTypeName: "bytea")
        }
        #expect(throws: DBValueParser.ParseError.binaryNotEditable) {
            try DBValueParser.parse("x", dbTypeName: "BLOB")
        }
    }

    @Test func everythingElsePassesAsString() throws {
        #expect(try DBValueParser.parse("hello", dbTypeName: "varchar(20)") == .string("hello"))
        #expect(try DBValueParser.parse("2024-01-01", dbTypeName: "timestamp") == .string("2024-01-01"))
        #expect(try DBValueParser.parse("{}", dbTypeName: "jsonb") == .string("{}"))
        // Token matching: Postgres "point" must not classify as integer.
        #expect(try DBValueParser.parse("(1,2)", dbTypeName: "point") == .string("(1,2)"))
    }
}
