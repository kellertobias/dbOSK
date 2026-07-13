import AppKit
import DBCore
import QueryEditor
import SwiftUI

/// Monospaced NSTextView with regex-based syntax highlighting. Deliberately
/// simple: whole-document rehighlight on change is fine at query sizes.
/// Swappable for a tree-sitter implementation behind the same interface later.
struct SyntaxTextEditor: NSViewRepresentable {
    @Binding var text: String
    let language: DriverDescriptor.QueryLanguage
    /// Enables table/column typeahead; SQL-family languages only.
    var completionProvider: SchemaCompletionProvider?

    func makeCoordinator() -> Coordinator {
        let completionApplies = language == .sql || language == .partiql
        return Coordinator(
            text: $text,
            highlighter: RegexHighlighter(language: language),
            completion: (completionApplies ? completionProvider : nil)
                .map(EditorCompletionController.init(provider:)))
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
        context.coordinator.completion?.attach(to: textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.completion?.hide()
            textView.string = text
            context.coordinator.highlight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let highlighter: RegexHighlighter
        let completion: EditorCompletionController?
        weak var textView: NSTextView?

        init(
            text: Binding<String>, highlighter: RegexHighlighter,
            completion: EditorCompletionController?
        ) {
            self.text = text
            self.highlighter = highlighter
            self.completion = completion
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            highlight()
            completion?.textDidChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            completion?.selectionDidChange()
        }

        func textDidEndEditing(_ notification: Notification) {
            completion?.hide()
        }

        func textView(
            _ textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            completion?.handleCommand(commandSelector) ?? false
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            highlighter.highlight(storage)
        }
    }
}

// MARK: - Completion glue

/// Connects the text view, the pure completion engine, the async schema
/// provider, and the popup panel: computes candidates on each edit, shows
/// what the caches hold immediately, and re-runs when async fetches land.
@MainActor
final class EditorCompletionController: NSObject {
    private let provider: SchemaCompletionProvider
    private let engine: CompletionEngine
    private let popup = CompletionPopupController()
    private weak var textView: NSTextView?

    /// Replacement range of the popup's current candidates.
    private var currentRange: NSRange?
    /// Cursor position of the last run that had columns on the way, so an
    /// async arrival can open the popup only if the caret hasn't moved.
    private var pendingCursor: Int?
    private var lastExplicit = false
    /// Text as of the last change, to tell caret-only moves apart from edits
    /// in `selectionDidChange` (which also fires while typing).
    private var lastText = ""
    /// Committing a suggestion re-enters `textDidChange`; without this the
    /// full inserted word would immediately re-open the popup.
    private var suppressNextChange = false

    init(provider: SchemaCompletionProvider) {
        self.provider = provider
        self.engine = CompletionEngine(identifierQuote: provider.identifierQuote)
        super.init()
        popup.onCommit = { [weak self] candidate in self?.commit(candidate) }
    }

    func attach(to textView: NSTextView, in scrollView: NSScrollView) {
        self.textView = textView
        lastText = textView.string
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(hideFromNotification),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowChanged(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowChanged(_:)),
            name: NSWindow.didMoveNotification, object: nil)
    }

    // MARK: Events from the coordinator

    func textDidChange() {
        lastText = textView?.string ?? ""
        if suppressNextChange {
            suppressNextChange = false
            popup.hide()
            return
        }
        run(explicit: false)
    }

    func selectionDidChange() {
        // Caret-only movement (arrows, clicks): re-anchor or dismiss. Edits
        // are handled by textDidChange, which fires after this.
        guard popup.isVisible, let textView, textView.string == lastText
        else { return }
        run(explicit: false)
    }

    func handleCommand(_ selector: Selector) -> Bool {
        if popup.isVisible {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                popup.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                popup.moveSelection(by: 1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                guard let selected = popup.selected else {
                    popup.hide()
                    return false
                }
                commit(selected)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                popup.hide()
                return true
            case #selector(NSResponder.moveLeft(_:)),
                 #selector(NSResponder.moveRight(_:)):
                popup.hide()
                return false
            default:
                return false
            }
        }
        // Ctrl+Space arrives as setMark: via the standard key bindings;
        // F5 as complete:.
        if selector == #selector(NSResponder.complete(_:))
            || selector == #selector(NSResponder.setMark(_:))
        {
            run(explicit: true)
            return true
        }
        return false
    }

    func hide() {
        popup.hide()
        pendingCursor = nil
    }

    // MARK: Completion runs

    private func run(explicit: Bool) {
        guard let textView, let window = textView.window,
              window.firstResponder === textView
        else {
            hide()
            return
        }
        let selection = textView.selectedRange()
        guard selection.length == 0 else {
            hide()
            return
        }

        let refresh: @MainActor () -> Void = { [weak self] in self?.refresh() }
        let result = engine.complete(
            text: textView.string, cursorUTF16: selection.location,
            schema: provider.snapshot(onUpdate: refresh), explicit: explicit)
        guard let result else {
            hide()
            return
        }

        lastExplicit = explicit
        if result.missingColumnTables.isEmpty {
            pendingCursor = nil
        } else {
            pendingCursor = selection.location
            provider.requestColumns(for: result.missingColumnTables, onUpdate: refresh)
        }

        guard !result.items.isEmpty else {
            popup.hide()  // keep pendingCursor: columns may still arrive
            return
        }
        currentRange = result.replacementRange
        let anchor = textView.firstRect(
            forCharacterRange: NSRange(
                location: result.replacementRange.location, length: 0),
            actualRange: nil)
        popup.show(items: result.items, near: anchor, parent: window)
    }

    /// Async schema data landed: re-run if the popup is open or the caret
    /// still sits where the pending request was made.
    private func refresh() {
        guard let textView else { return }
        let cursor = textView.selectedRange().location
        guard popup.isVisible || cursor == pendingCursor else { return }
        run(explicit: lastExplicit)
    }

    private func commit(_ candidate: CompletionCandidate) {
        guard let textView, let range = currentRange else { return }
        suppressNextChange = true
        textView.insertText(candidate.insertText, replacementRange: range)
        popup.hide()
        pendingCursor = nil
    }

    @objc private func hideFromNotification() {
        hide()
    }

    @objc private func windowChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === textView?.window
        else { return }
        hide()
    }
}
