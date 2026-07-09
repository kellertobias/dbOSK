import AppKit
import Connections
import DBCore
import Export
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: ConnectionSession

    var body: some View {
        VStack(spacing: 0) {
            // Always-visible environment stripe (e.g. red = production).
            if let label = appModel.label(for: session.profile) {
                Rectangle()
                    .fill(label.colorTag.color)
                    .frame(height: 3)
            }
            NavigationSplitView {
                SidebarView(session: session)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240)
            } detail: {
                VStack(spacing: 0) {
                    TabBarView(session: session)
                    Divider()
                    tabContent
                }
            }
        }
        .navigationTitle(session.profile.name)
        .navigationSubtitle(session.profile.groupName ?? "")
        .toolbar {
            if let label = appModel.label(for: session.profile) {
                ToolbarItem(placement: .primaryAction) {
                    LabelBadge(label: label)
                }
            }
        }
        .task { await session.loadRoot() }
        // Closing the window ends the session — no separate disconnect control.
        .onDisappear { appModel.disconnect(profileID: session.profile.id) }
    }

    @ViewBuilder
    private var tabContent: some View {
        if let tab = session.selectedTab {
            switch tab.content {
            case .query(let queryTab):
                QueryView(tab: queryTab, session: session)
            case .table(let browser):
                TableModeView(browser: browser, session: session)
            }
        } else {
            ContentUnavailableView(
                "No Tab Open",
                systemImage: "tablecells",
                description: Text(
                    "Click a table in the sidebar, or the SQL button on a schema."))
        }
    }
}

// MARK: - Tab bar

struct TabBarView: View {
    @Bindable var session: ConnectionSession

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 4)
            }
            Button {
                session.openQueryTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New query tab")
            .padding(.trailing, 6)
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func tabButton(_ tab: WorkTab) -> some View {
        let isSelected = session.selectedTabID == tab.id
        return HStack(spacing: 4) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
            Button {
                session.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTabID = tab.id }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var session: ConnectionSession
    @State private var hoveredNodeID: String?
    @State private var noteTarget: DBCore.Namespace?
    @State private var groupTarget: DBCore.Namespace?
    @State private var newGroupName = ""

    var body: some View {
        List {
            if let error = session.sidebarError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            if !session.metadata.savedQueries.isEmpty {
                Section("Saved Queries") {
                    ForEach(session.metadata.savedQueries) { saved in
                        savedQueryRow(saved)
                    }
                }
            }
            Section {
                OutlineGroup(
                    session.rootNamespaces.map {
                        SidebarNode(kind: .namespace($0, parent: nil), session: session)
                    },
                    children: \.children
                ) { node in
                    row(for: node)
                }
            } header: {
                HStack(spacing: 8) {
                    Text(session.profile.database ?? "Objects")
                    Spacer()
                    if session.editingVisibility {
                        Button("All") { session.setAllTablesVisible(true) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Select all tables")
                        Button("None") { session.setAllTablesVisible(false) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Deselect all tables")
                        Button("Done") { session.editingVisibility = false }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                    } else {
                        if !session.metadata.tables.filter(\.value.hidden).isEmpty {
                            Button {
                                session.showHiddenTables.toggle()
                            } label: {
                                Image(systemName: session.showHiddenTables
                                    ? "eye" : "eye.slash")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help(session.showHiddenTables
                                ? "Showing hidden tables" : "Show hidden tables")
                        }
                        Button {
                            session.editingVisibility = true
                        } label: {
                            Image(systemName: "checklist")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Choose which tables to show")
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .sheet(item: $noteTarget) { namespace in
            NoteEditorView(session: session, namespace: namespace)
        }
        .alert("New Group", isPresented: groupAlertShown) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) { groupTarget = nil }
            Button("Create") {
                if let target = groupTarget, !newGroupName.isEmpty {
                    session.setGroup(newGroupName, for: target)
                }
                groupTarget = nil
                newGroupName = ""
            }
        } message: {
            Text("Group tables within their schema in the sidebar.")
        }
    }

    private var groupAlertShown: Binding<Bool> {
        Binding(
            get: { groupTarget != nil },
            set: { if !$0 { groupTarget = nil } })
    }

    private func savedQueryRow(_ saved: SavedQuery) -> some View {
        Label(saved.name, systemImage: "bookmark")
            .contentShape(Rectangle())
            .onTapGesture {
                session.openQueryTab(initialSQL: saved.text)
            }
            .help(saved.text)
            .contextMenu {
                Button("Open") { session.openQueryTab(initialSQL: saved.text) }
                Button("Run") {
                    session.openQueryTab(initialSQL: saved.text, runImmediately: true)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    session.deleteSavedQuery(saved)
                }
            }
    }

    @ViewBuilder
    private func row(for node: SidebarNode) -> some View {
        switch node.kind {
        case .group(let name, let parent):
            HStack(spacing: 4) {
                if session.editingVisibility {
                    groupCheckbox(name: name, parent: parent)
                }
                Label(name, systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
            }
        case .namespace(let namespace, let parent):
            namespaceRow(namespace, parent: parent, nodeID: node.id)
        }
    }

    /// Checkbox for a whole group: checked / unchecked / mixed.
    private func groupCheckbox(name: String, parent: DBCore.Namespace) -> some View {
        let tables = session.allTables(in: parent)
            .filter { session.group(for: $0) == name }
        let visibleCount = tables.filter { !session.isHidden($0) }.count
        let symbol = visibleCount == tables.count
            ? "checkmark.square.fill"
            : (visibleCount == 0 ? "square" : "minus.square.fill")
        return Button {
            session.setGroupVisible(visibleCount != tables.count, group: name, in: parent)
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(visibleCount == 0 ? .secondary : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .help("Show or hide all tables in \(name)")
    }

    private func namespaceRow(
        _ namespace: DBCore.Namespace, parent: DBCore.Namespace?, nodeID: String
    ) -> some View {
        let isHidden = session.isHidden(namespace)
        let note = session.note(for: namespace)
        return HStack(spacing: 4) {
            if session.editingVisibility, namespace.kind.isTable {
                Image(systemName: isHidden ? "square" : "checkmark.square.fill")
                    .foregroundStyle(isHidden ? .secondary : Color.accentColor)
            }
            Label(namespace.name, systemImage: SidebarNode.icon(for: namespace))
                .foregroundStyle(isHidden ? .tertiary : .primary)
            if note != nil {
                Image(systemName: "note.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            // Raw-query shortcut on database/schema nodes.
            if namespace.isExpandable, hoveredNodeID == nodeID,
               !session.editingVisibility {
                Button {
                    session.openQueryTab()
                } label: {
                    Text("SQL")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.2)))
                }
                .buttonStyle(.borderless)
                .help("New query on \(namespace.name)")
            }
        }
        .help(note ?? "")
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredNodeID = hovering ? nodeID : nil
        }
        .onTapGesture {
            guard case .table = namespace.kind else { return }
            if session.editingVisibility {
                session.setHidden(!isHidden, for: namespace)
            } else {
                session.openTable(namespace)
            }
        }
        .contextMenu {
            if case .table = namespace.kind {
                tableContextMenu(namespace, parent: parent)
            } else {
                Button("New Query") { session.openQueryTab() }
                Button("Show All Tables") { session.unhideAll(in: namespace) }
            }
        }
    }

    @ViewBuilder
    private func tableContextMenu(
        _ namespace: DBCore.Namespace, parent: DBCore.Namespace?
    ) -> some View {
        Button("Open Table") { session.openTable(namespace) }
        Button("Query Table") {
            session.openQueryTab(
                initialSQL: SidebarNode.defaultQuery(for: namespace, in: session),
                runImmediately: true)
        }
        Divider()
        Button(session.note(for: namespace) == nil ? "Add Note…" : "Edit Note…") {
            noteTarget = namespace
        }
        Menu("Group") {
            ForEach(session.metadata.groupNames, id: \.self) { group in
                Button {
                    session.setGroup(group, for: namespace)
                } label: {
                    if session.group(for: namespace) == group {
                        Label(group, systemImage: "checkmark")
                    } else {
                        Text(group)
                    }
                }
            }
            if !session.metadata.groupNames.isEmpty { Divider() }
            Button("New Group…") { groupTarget = namespace }
            if session.group(for: namespace) != nil {
                Button("Remove from Group") { session.setGroup(nil, for: namespace) }
            }
        }
        Divider()
        Button(session.isHidden(namespace) ? "Unhide Table" : "Hide Table") {
            session.setHidden(!session.isHidden(namespace), for: namespace)
        }
        Button("Choose Visible Tables…") { session.editingVisibility = true }
        if let parent {
            Button("Show All Tables") { session.unhideAll(in: parent) }
        }
    }
}

/// Sidebar tree node: a real namespace or a user-defined table group.
@MainActor
struct SidebarNode: @MainActor Identifiable {
    enum Kind {
        case namespace(DBCore.Namespace, parent: DBCore.Namespace?)
        case group(String, parent: DBCore.Namespace)
    }

    let kind: Kind
    let session: ConnectionSession

    var id: String {
        switch kind {
        case .namespace(let namespace, _): return namespace.id
        case .group(let name, let parent): return parent.id + "#group:" + name
        }
    }

    var children: [SidebarNode]? {
        switch kind {
        case .group(let name, let parent):
            return visibleTables(of: parent)
                .filter { session.group(for: $0) == name }
                .map { SidebarNode(kind: .namespace($0, parent: parent), session: session) }
        case .namespace(let namespace, _):
            guard namespace.isExpandable else { return nil }
            guard let loaded = session.children[namespace.id] else {
                // Trigger lazy load; OutlineGroup re-renders when children update.
                Task { await session.loadChildren(of: namespace) }
                return []
            }
            var nodes: [SidebarNode] = loaded
                .filter { !$0.kind.isTable }
                .map { SidebarNode(kind: .namespace($0, parent: namespace), session: session) }
            let tables = visibleTables(of: namespace)
            let groups = Set(tables.compactMap { session.group(for: $0) }).sorted()
            nodes += groups.map {
                SidebarNode(kind: .group($0, parent: namespace), session: session)
            }
            nodes += tables
                .filter { session.group(for: $0) == nil }
                .map { SidebarNode(kind: .namespace($0, parent: namespace), session: session) }
            return nodes
        }
    }

    private func visibleTables(of parent: DBCore.Namespace) -> [DBCore.Namespace] {
        (session.children[parent.id] ?? [])
            .filter(\.kind.isTable)
            .filter {
                session.editingVisibility || session.showHiddenTables
                    || !session.isHidden($0)
            }
    }

    static func icon(for namespace: DBCore.Namespace) -> String {
        switch namespace.kind {
        case .database: return "cylinder"
        case .schema: return "folder"
        case .table(.view): return "eye"
        case .table(.collection): return "doc.text"
        case .table: return "tablecells"
        }
    }

    static func defaultQuery(
        for namespace: DBCore.Namespace, in session: ConnectionSession
    ) -> String {
        let descriptor = session.descriptor
        if descriptor.queryLanguage == .mongo {
            return "db.\(namespace.path.joined(separator: ".")).find({}).limit(100)"
        }
        let path = namespace.path.map { descriptor.quoted($0) }.joined(separator: ".")
        return "SELECT * FROM \(path) LIMIT 100;"
    }
}

extension DBCore.Namespace.Kind {
    var isTable: Bool {
        if case .table = self { return true }
        return false
    }
}

// MARK: - Note editor

struct NoteEditorView: View {
    let session: ConnectionSession
    let namespace: DBCore.Namespace
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(namespace.path.joined(separator: "."), systemImage: "note.text")
                .font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                if session.note(for: namespace) != nil {
                    Button("Remove Note", role: .destructive) {
                        session.setNote(nil, for: namespace)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    session.setNote(text, for: namespace)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { text = session.note(for: namespace) ?? "" }
    }
}

/// Picks the right renderer: document-shaped results (Mongo) get the
/// two-column list + tree view, everything else the flat table.
struct ResultsArea: View {
    let columns: [ColumnMeta]
    let rows: [ResultRow]
    let version: Int

    var body: some View {
        if columns.count == 1, columns[0].dbTypeName == "document" {
            DocumentResultsView(rows: rows)
        } else {
            ResultsTableView(columns: columns, rows: rows, version: version)
        }
    }
}

// MARK: - Query view

struct QueryView: View {
    @Bindable var tab: QueryTab
    let session: ConnectionSession
    @State private var savingQuery = false
    @State private var savedQueryName = ""

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                SyntaxTextEditor(text: $tab.queryText, language: tab.language)
                    .frame(minHeight: 80)
                statusBar
            }
            ResultsArea(columns: tab.columns, rows: tab.rows, version: tab.resultVersion)
                .frame(minHeight: 120)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    savedQueryName = ""
                    savingQuery = true
                } label: {
                    Label("Save Query", systemImage: "bookmark")
                }
                .disabled(tab.queryText.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
                .help("Save this query to the sidebar")
                ExportMenu(tab: tab)
                if tab.runState == .running || tab.runState == .streaming {
                    Button {
                        tab.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        tab.run()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .alert("Save Query", isPresented: $savingQuery) {
            TextField("Name", text: $savedQueryName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = savedQueryName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                session.saveQuery(named: name, text: tab.queryText)
            }
        } message: {
            Text("Saved queries appear in the sidebar for this connection.")
        }
    }

    private var statusBar: some View {
        HStack {
            switch tab.runState {
            case .idle:
                Text("Ready")
            case .running:
                ProgressView().controlSize(.small)
                Text("Running…")
            case .streaming:
                ProgressView().controlSize(.small)
                Text("Streaming… \(tab.rows.count) rows")
            case .done(let count, let elapsed):
                Text("\(count) rows in \(String(format: "%.2f", elapsed))s")
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                Text("Cancelled").foregroundStyle(.orange)
            }
            Spacer()
            ExportStatusView(tab: tab)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

// MARK: - Export UI

struct ExportMenu: View {
    let tab: QueryTab

    var body: some View {
        Menu {
            Button("Export as CSV…") { save(.csv) }
            Button("Export as JSON…") { save(.json) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(tab.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Re-runs the query and streams the full result to a file")
    }

    private func save(_ format: Export.ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "results.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            tab.export(format: format, to: url)
        }
    }
}

struct ExportStatusView: View {
    let tab: QueryTab

    var body: some View {
        switch tab.exportState {
        case .idle:
            EmptyView()
        case .exporting(let rows):
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Exporting… \(rows) rows")
            }
        case .done(let url):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle")
            }
            .buttonStyle(.link)
            .font(.caption)
        case .failed(let message):
            Text("Export failed: \(message)")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}
