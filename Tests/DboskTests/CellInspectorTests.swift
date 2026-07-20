import Foundation
import Testing

@testable import Dbosk

@Suite struct CellInspectorTests {
    // MARK: prettyJSON

    @Test func prettyPrintsJSONObjectString() {
        let pretty = CellInspectorView.prettyJSON(from: #"{"b":1,"a":2}"#)
        // Pretty-printed, sorted keys, one field per line.
        #expect(pretty == "{\n  \"a\" : 2,\n  \"b\" : 1\n}")
    }

    @Test func prettyPrintsJSONArrayString() {
        let pretty = CellInspectorView.prettyJSON(from: "[1,2]")
        #expect(pretty == "[\n  1,\n  2\n]")
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(CellInspectorView.prettyJSON(from: "  {\"a\":1}\n") != nil)
    }

    @Test func rejectsPlainStrings() {
        #expect(CellInspectorView.prettyJSON(from: "just a sentence") == nil)
        #expect(CellInspectorView.prettyJSON(from: "42") == nil)
        // Looks like it starts an object but doesn't parse.
        #expect(CellInspectorView.prettyJSON(from: "{not valid}") == nil)
    }

    // MARK: JSONHighlighter

    @Test func highlightPreservesText() {
        let source = "{\n  \"a\" : 1,\n  \"b\" : [true, null]\n}"
        let highlighted = JSONHighlighter.highlight(source)
        #expect(String(highlighted.characters) == source)
    }

    @Test func distinguishesKeysFromStringValues() {
        let highlighted = JSONHighlighter.highlight(#"{"key":"value"}"#)
        // A key and a string value with identical spelling still get distinct
        // colors, so the scanner must be looking past the closing quote.
        let key = JSONHighlighter.highlight(#"{"x":"x"}"#)
        #expect(String(highlighted.characters) == #"{"key":"value"}"#)
        #expect(String(key.characters) == #"{"x":"x"}"#)
    }
}
