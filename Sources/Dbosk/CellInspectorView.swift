import AppKit
import DBCore
import Foundation
import SwiftUI

/// One cell chosen for inspection in the trailing sidebar. Carries everything
/// the inspector renders from, so it survives selection changes in the table.
struct InspectedCell: Identifiable, Equatable {
    let id = UUID()
    let columnName: String
    let columnType: String
    let value: DBValue
}

/// Trailing sidebar that shows a single cell's full value: pretty-printed and
/// syntax-highlighted when it's JSON (a document/array, or a string that
/// parses as JSON), plain wrapped text otherwise. Long strings that would be
/// truncated to one line in the grid become fully readable here.
struct CellInspectorView: View {
    let cell: InspectedCell
    var onClose: () -> Void

    /// What to render, decided once from the cell's value.
    private enum Rendering {
        case json(AttributedString, raw: String)
        case plain(String)
        case null
    }

    private var rendering: Rendering {
        switch cell.value {
        case .null:
            return .null
        case .document, .array:
            let raw = cell.value.jsonString(prettyPrinted: true)
            return .json(JSONHighlighter.highlight(raw), raw: raw)
        case .string(let string):
            if let pretty = Self.prettyJSON(from: string) {
                return .json(JSONHighlighter.highlight(pretty), raw: pretty)
            }
            return .plain(string)
        default:
            return .plain(cell.value.displayString)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView([.vertical, .horizontal]) {
                content
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(cell.columnName)
                    .font(.headline)
                    .lineLimit(1)
                Text(kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                copyRawToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy value")
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close inspector")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var kindLabel: String {
        switch rendering {
        case .json: return "\(cell.columnType) · JSON"
        case .plain: return cell.columnType
        case .null: return cell.columnType
        }
    }

    @ViewBuilder
    private var content: some View {
        switch rendering {
        case .json(let attributed, _):
            Text(attributed)
                .font(.system(.callout, design: .monospaced))
        case .plain(let string):
            Text(string)
                .font(.system(.callout, design: .monospaced))
        case .null:
            Text("NULL")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var rawText: String {
        switch rendering {
        case .json(_, let raw): return raw
        case .plain(let string): return string
        case .null: return "NULL"
        }
    }

    private func copyRawToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawText, forType: .string)
    }

    /// Pretty-prints a string that is itself JSON (object or array); returns
    /// nil for anything that doesn't parse, so plain strings stay plain.
    static func prettyJSON(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8)
        else { return nil }
        return result
    }
}

/// Colors JSON text into an `AttributedString`. Hand-rolled scanner (rather
/// than regexes) so property keys and string values can be told apart. Colors
/// are semantic SwiftUI colors, so light and dark mode both read well.
enum JSONHighlighter {
    static func highlight(_ json: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(json)
        let count = chars.count
        var i = 0

        func emit(_ text: String, _ color: Color?) {
            var fragment = AttributedString(text)
            if let color { fragment.foregroundColor = color }
            out.append(fragment)
        }

        while i < count {
            let c = chars[i]

            // Strings: read to the closing quote, honoring escapes, then peek
            // ahead for a ':' to distinguish a key from a value.
            if c == "\"" {
                var j = i + 1
                while j < count {
                    if chars[j] == "\\", j + 1 < count {
                        j += 2
                        continue
                    }
                    if chars[j] == "\"" {
                        j += 1
                        break
                    }
                    j += 1
                }
                let token = String(chars[i..<min(j, count)])
                var k = j
                while k < count, chars[k] == " " || chars[k] == "\n"
                    || chars[k] == "\t" || chars[k] == "\r" {
                    k += 1
                }
                let isKey = k < count && chars[k] == ":"
                emit(token, isKey ? .blue : .red)
                i = j
                continue
            }

            // Numbers.
            if c == "-" || c.isNumber {
                var j = i
                while j < count, "0123456789+-.eE".contains(chars[j]) {
                    j += 1
                }
                emit(String(chars[i..<j]), .purple)
                i = j
                continue
            }

            // Literals.
            if let keyword = ["true", "false", "null"].first(where: {
                matches($0, in: chars, at: i)
            }) {
                emit(keyword, .orange)
                i += keyword.count
                continue
            }

            // Structural punctuation vs. plain whitespace.
            let isPunct = "{}[]:,".contains(c)
            emit(String(c), isPunct ? .secondary : nil)
            i += 1
        }
        return out
    }

    private static func matches(_ keyword: String, in chars: [Character], at index: Int) -> Bool {
        let keywordChars = Array(keyword)
        guard index + keywordChars.count <= chars.count else { return false }
        for offset in 0..<keywordChars.count where chars[index + offset] != keywordChars[offset] {
            return false
        }
        return true
    }
}
