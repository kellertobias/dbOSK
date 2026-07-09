import Foundation
import Testing

@testable import DBCore

@Suite struct SQLLiteralEncoderTests {
    @Test func nullAndNumbers() throws {
        #expect(try SQLLiteralEncoder.literal(.null, dialect: .postgres) == "NULL")
        #expect(try SQLLiteralEncoder.literal(.int(-42), dialect: .postgres) == "-42")
        #expect(try SQLLiteralEncoder.literal(.double(1.5), dialect: .mysql) == "1.5")
        #expect(try SQLLiteralEncoder.literal(.decimal("12.340"), dialect: .postgres) == "12.340")
        #expect(try SQLLiteralEncoder.literal(.decimal(" -1e10 "), dialect: .postgres) == "-1e10")
    }

    @Test func rejectsNonNumericDecimal() {
        // The decimal path is emitted raw, so it must never pass through SQL.
        #expect(throws: DBError.self) {
            try SQLLiteralEncoder.literal(.decimal("1; DROP TABLE x"), dialect: .postgres)
        }
        #expect(throws: DBError.self) {
            try SQLLiteralEncoder.literal(.double(.infinity), dialect: .postgres)
        }
    }

    @Test func booleansPerDialect() throws {
        #expect(try SQLLiteralEncoder.literal(.bool(true), dialect: .postgres) == "TRUE")
        #expect(try SQLLiteralEncoder.literal(.bool(false), dialect: .mysql) == "FALSE")
        #expect(try SQLLiteralEncoder.literal(.bool(true), dialect: .sqlite) == "1")
        #expect(try SQLLiteralEncoder.literal(.bool(false), dialect: .sqlite) == "0")
    }

    @Test func stringEscaping() throws {
        #expect(try SQLLiteralEncoder.literal(.string("it's"), dialect: .postgres) == "'it''s'")
        #expect(try SQLLiteralEncoder.literal(.string(#"a\b"#), dialect: .postgres) == #"'a\b'"#)
        // MySQL treats backslash as escape under default sql_mode.
        #expect(try SQLLiteralEncoder.literal(.string(#"a\b"#), dialect: .mysql) == #"'a\\b'"#)
        #expect(try SQLLiteralEncoder.literal(.string(#"\'"#), dialect: .mysql) == #"'\\'''"#)
    }

    @Test func bytesPerDialect() throws {
        let data = DBValue.bytes(Data([0x01, 0xAB]))
        #expect(try SQLLiteralEncoder.literal(data, dialect: .postgres) == #"'\x01ab'::bytea"#)
        #expect(try SQLLiteralEncoder.literal(data, dialect: .mysql) == "X'01ab'")
        #expect(try SQLLiteralEncoder.literal(data, dialect: .sqlite) == "X'01ab'")
    }

    @Test func datesAndUUIDs() throws {
        let date = Date(timeIntervalSince1970: 0)
        let postgres = try SQLLiteralEncoder.literal(.date(date), dialect: .postgres)
        #expect(postgres.hasPrefix("'1970-01-01T00:00:00"))
        #expect(postgres.hasSuffix("Z'"))
        // MySQL rejects the Z suffix.
        let mysql = try SQLLiteralEncoder.literal(.date(date), dialect: .mysql)
        #expect(!mysql.contains("Z"))

        let uuid = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        #expect(try SQLLiteralEncoder.literal(.uuid(uuid), dialect: .postgres)
            == "'6ba7b810-9dad-11d1-80b4-00c04fd430c8'")
    }

    @Test func documentsEncodeAsJSONStrings() throws {
        let value = DBValue.document(["a": .int(1)])
        #expect(try SQLLiteralEncoder.literal(value, dialect: .postgres) == #"'{"a":1}'"#)
    }

    @Test func unsupportedThrows() {
        #expect(throws: DBError.self) {
            try SQLLiteralEncoder.literal(
                .unsupported(typeName: "geometry", text: "..."), dialect: .postgres)
        }
    }
}
