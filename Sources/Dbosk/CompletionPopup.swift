import AppKit
import QueryEditor

/// Borderless, non-activating panel showing completion candidates below the
/// caret. Never takes key focus — the text view keeps first responder and
/// forwards navigation/commit keys via `moveSelection`/`selected`.
@MainActor
final class CompletionPopupController: NSObject {
    private let panel: NSPanel
    private let tableView = CompletionTableView()
    private let scrollView = NSScrollView()
    private var items: [CompletionCandidate] = []
    private weak var parentWindow: NSWindow?

    var onCommit: ((CompletionCandidate) -> Void)?

    private static let rowHeight: CGFloat = 22
    private static let width: CGFloat = 360
    private static let maxVisibleRows = 10

    var isVisible: Bool { panel.isVisible }

    var selected: CompletionCandidate? {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true)
        super.init()

        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: .init("candidate"))
        column.width = Self.width - 8
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(scrollView)
        panel.contentView = background
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(
                equalTo: background.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(
                equalTo: background.bottomAnchor, constant: -4),
        ])
    }

    /// Shows (or repositions) the popup anchored to `caretScreenRect`,
    /// flipping above the caret near the bottom of the screen.
    func show(
        items: [CompletionCandidate], near caretScreenRect: NSRect, parent: NSWindow
    ) {
        self.items = items
        tableView.reloadData()
        selectRow(0)

        let visibleRows = min(items.count, Self.maxVisibleRows)
        let height = CGFloat(visibleRows) * Self.rowHeight + 8
        var origin = NSPoint(
            x: caretScreenRect.minX - 4, y: caretScreenRect.minY - height - 2)
        if let screen = parent.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            if origin.y < frame.minY {
                origin.y = caretScreenRect.maxY + 2
            }
            origin.x = min(origin.x, frame.maxX - Self.width)
        }
        panel.setFrame(
            NSRect(x: origin.x, y: origin.y, width: Self.width, height: height),
            display: false)

        if !panel.isVisible {
            parent.addChildWindow(panel, ordered: .above)
            parentWindow = parent
            panel.orderFront(nil)
        }
    }

    /// Replaces the candidate list in place (async column data arrived).
    func update(items: [CompletionCandidate]) {
        guard isVisible else { return }
        self.items = items
        tableView.reloadData()
        selectRow(0)
        let visibleRows = min(items.count, Self.maxVisibleRows)
        var frame = panel.frame
        let height = CGFloat(visibleRows) * Self.rowHeight + 8
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    func hide() {
        guard panel.isVisible else { return }
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil
        panel.orderOut(nil)
        items = []
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, tableView.selectedRow + delta))
        selectRow(row)
    }

    private func selectRow(_ row: Int) {
        guard row < items.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onCommit?(items[row])
    }
}

// MARK: - Table view plumbing

extension CompletionPopupController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("candidateCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? CompletionCellView ?? CompletionCellView(identifier: identifier)
        cell.configure(with: items[row])
        return cell
    }
}

/// First mouse activates rows immediately, matching menu behavior.
private final class CompletionTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

private final class CompletionCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        labelField.lineBreakMode = .byTruncatingTail
        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.alignment = .right
        detailField.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(labelField)
        addSubview(detailField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            labelField.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: 6),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.leadingAnchor.constraint(
                greaterThanOrEqualTo: labelField.trailingAnchor, constant: 12),
            detailField.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -8),
            detailField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(with candidate: CompletionCandidate) {
        labelField.stringValue = candidate.label
        detailField.stringValue = candidate.detail
        let symbol: String
        switch candidate.kind {
        case .table: symbol = "tablecells"
        case .column: symbol = "list.bullet"
        case .schema: symbol = "folder"
        case .keyword: symbol = "textformat"
        }
        iconView.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: nil)
    }
}
