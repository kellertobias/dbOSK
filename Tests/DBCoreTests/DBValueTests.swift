import Foundation
import Testing

@testable import DBCore

@Suite struct DBValueTests {
    @Test func displayStrings() {
        #expect(DBValue.null.displayString == "NULL")
        #expect(DBValue.int(42).displayString == "42")
        #expect(DBValue.bool(true).displayString == "true")
        #expect(DBValue.decimal("123.4500").displayString == "123.4500")
        #expect(DBValue.string("hi").displayString == "hi")
        #expect(DBValue.bytes(Data([1, 2, 3])).displayString == "0x… (3 bytes)")
    }

    @Test func jsonRoundtrip() throws {
        let value = DBValue.document([
            "name": .string("ada"),
            "age": .int(36),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .document(["active": .bool(true), "score": .double(1.5)]),
            "none": .null,
        ])
        let json = value.jsonString(prettyPrinted: false)
        let parsed = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["name"] as? String == "ada")
        #expect(parsed?["age"] as? Int == 36)
        #expect((parsed?["tags"] as? [String]) == ["a", "b"])
        #expect((parsed?["meta"] as? [String: Any])?["active"] as? Bool == true)
        #expect(parsed?["none"] is NSNull)
    }

    @Test func jsonScalarFragment() {
        #expect(DBValue.int(7).jsonString(prettyPrinted: false) == "7")
        #expect(DBValue.string("x").jsonString(prettyPrinted: false) == "\"x\"")
    }
}
