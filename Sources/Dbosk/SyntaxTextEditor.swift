import AppKit
import DBCore
import SwiftUI

/// Monospaced NSTextView with regex-based syntax highlighting. Deliberately
/// simple: whole-document rehighlight on change is fine at query sizes.
/// Swappable for a tree-sitter implementation behind the same interface later.
struct SyntaxTextEditor: NSViewRepresentable {
    @Binding var text: String
    let language: DriverDescriptor.QueryLanguage

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, highlighter: RegexHighlighter(language: language))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let highlighter: RegexHighlighter
        weak var textView: NSTextView?

        init(text: Binding<String>, highlighter: RegexHighlighter) {
            self.text = text
            self.highlighter = highlighter
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            highlight()
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            highlighter.highlight(storage)
        }
    }
}

// MARK: - Highlighter

/// Applies token colors via regular expressions. Colors are semantic system
/// colors, so light/dark mode both work.
final class RegexHighlighter {
    private struct Rule {
        let regex: NSRegularExpression
        let color: NSColor
    }

    private let rules: [Rule]

    init(language: DriverDescriptor.QueryLanguage) {
        var rules: [Rule] = []
        func add(_ pattern: String, _ color: NSColor, options: NSRegularExpression.Options = []) {
            if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                rules.append(Rule(regex: regex, color: color))
            }
        }

        switch language {
        case .sql, .partiql:
            let keywords = [
                "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE",
                "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "JOIN", "LEFT", "RIGHT",
                "INNER", "OUTER", "FULL", "CROSS", "ON", "AS", "GROUP", "BY",
                "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
                "CASE", "WHEN", "THEN", "ELSE", "END", "LIKE", "ILIKE", "BETWEEN",
                "EXISTS", "ASC", "DESC", "WITH", "RECURSIVE", "RETURNING", "CAST",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "TRUE", "FALSE",
            ]
            add(#"\b(\#(keywords.joined(separator: "|")))\b"#, .systemBlue,
                options: [.caseInsensitive])
            add(#"\b\d+(\.\d+)?\b"#, .systemPurple)
            add(#"'(?:[^']|'')*'"#, .systemRed)
            add(#"--[^\n]*"#, .systemGray)
            add(#"/\*.*?\*/"#, .systemGray, options: [.dotMatchesLineSeparators])

        case .mongo:
            add(#"\b(db|find|aggregate|count|skip|limit|sort|project)\b"#, .systemBlue)
            add(#"\$[a-zA-Z]+\b"#, .systemTeal)
            add(#"\b\d+(\.\d+)?\b"#, .systemPurple)
            add(#""(?:[^"\\]|\\.)*""#, .systemRed)
            add(#"\b(true|false|null)\b"#, .systemOrange)

        case .redis:
            add(#"^\s*[A-Z]+\b"#, .systemBlue, options: [.anchorsMatchLines])
            add(#""(?:[^"\\]|\\.)*""#, .systemRed)
        }

        self.rules = rules
    }

    func highlight(_ storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        for rule in rules {
            rule.regex.enumerateMatches(in: storage.string, range: fullRange) {
                match, _, _ in
                guard let range = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: rule.color, range: range)
            }
        }
        storage.endEditing()
    }
}
