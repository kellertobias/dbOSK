import DBCore
import SwiftUI

/// Full Table mode: browse one table with column selection, WHERE filter,
/// and limit/offset paging. Builds a SELECT and reuses the streaming runner.
struct TableModeView: View {
    @Bindable var browser: TableBrowser
    var session: ConnectionSession?
    /// Statements shown in the pre-apply SQL preview sheet.
    @State private var applyPreview: SQLApplyPreview?
    /// nil until the user picks explicitly, so the shape-based default
    /// still applies when the browsed table changes shape.
    @State private var viewMode: ResultsViewMode?

    private struct SQLApplyPreview: Identifiable {
        let id = UUID()
        let statements: [String]
    }

    var body: some View {
        if browser.table == nil {
            ContentUnavailableView(
                "No Table Selected",
                systemImage: "tablecells",
                description: Text("Select a table in the sidebar."))
        } else {
            VStack(spacing: 0) {
                if browser.displayMode == .data {
                    controls
                    Divider()
                    ResultsArea(
                        columns: browser.resultTab.columns,
                        rows: browser.displayRows,
                        version: browser.displayVersion,
                        mode: ResultsViewMode.effective(
                            viewMode, columns: browser.resultTab.columns),
                        editing: browser.editingConfig)
                    statusBar
                } else {
                    structureHeader
                    Divider()
                    TableStructureView(browser: browser)
                }
            }
            .sheet(item: $applyPreview) { preview in
                ApplyPreviewSheet(statements: preview.statements) {
                    browser.apply(statements: preview.statements)
                }
            }
            .confirmationDialog(
                "Discard pending changes?",
                isPresented: Binding(
                    get: { browser.pendingNavigation != nil },
                    set: { if !$0 { browser.cancelPendingNavigation() } })
            ) {
                Button("Discard & Continue", role: .destructive) {
                    browser.confirmPendingNavigation()
                }
                Button("Cancel", role: .cancel) {
                    browser.cancelPendingNavigation()
                }
            } message: {
                Text("You have \(browser.pending.summary) that have not been applied.")
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Spacer()
                    modePicker
                    if browser.displayMode == .data {
                        ExportMenu(tab: browser.resultTab)
                        if browser.resultTab.runState == .running
                            || browser.resultTab.runState == .streaming {
                            Button {
                                browser.resultTab.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                        } else {
                            Button {
                                browser.requestNavigation { browser.load() }
                            } label: {
                                Label("Load", systemImage: "play.fill")
                            }
                            .keyboardShortcut(.return, modifiers: .command)
                        }
                    } else {
                        Button {
                            browser.loadStructure(reload: true)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(browser.isLoadingStructure)
                        .help("Reload the table structure")
                    }
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { browser.displayMode },
            set: { browser.setDisplayMode($0) }
        )) {
            ForEach(TableBrowser.DisplayMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .help("Switch between table data and structure")
    }

    /// Structure mode keeps the same table title/note header as data mode,
    /// without the filter and paging controls.
    private var structureHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(browser.table?.path.joined(separator: ".") ?? "",
                      systemImage: "tablecells")
                    .font(.headline)
                Spacer()
                if browser.isLoadingStructure {
                    ProgressView().controlSize(.small)
                }
            }
            if let session, let table = browser.table,
               let note = session.note(for: table) {
                Label(note, systemImage: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(browser.table?.path.joined(separator: ".") ?? "",
                      systemImage: "tablecells")
                    .font(.headline)
                Spacer()
                if browser.isLoadingColumns {
                    ProgressView().controlSize(.small)
                }
                // Column projection is SQL-only in v1.
                if browser.descriptor.queryLanguage != .mongo {
                    columnsMenu
                        .disabled(browser.isLoadingColumns)
                }
            }
            if let session, let table = browser.table,
               let note = session.note(for: table) {
                Label(note, systemImage: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Text(browser.descriptor.queryLanguage == .mongo ? "FILTER" : "WHERE")
                    .font(.caption).foregroundStyle(.secondary)
                TextField(
                    browser.descriptor.queryLanguage == .mongo
                        ? #"JSON filter, e.g. {"status": "active"}"#
                        : "condition, e.g. status = 'active'",
                    text: $browser.whereClause)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    browser.requestNavigation {
                        browser.offset = 0
                        browser.load()
                    }
                }
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Start").font(.caption).foregroundStyle(.secondary)
                    TextField("0", value: $browser.offset, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { browser.requestNavigation { browser.load() } }
                }
                HStack(spacing: 4) {
                    Text("Rows").font(.caption).foregroundStyle(.secondary)
                    TextField("100", value: $browser.limit, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            browser.requestNavigation {
                                browser.offset = 0
                                browser.load()
                            }
                        }
                }
                Button {
                    browser.previousPage()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(browser.offset == 0)
                .help("Previous page")
                Button {
                    browser.nextPage()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next page")
                if browser.isEditable {
                    Divider().frame(height: 16)
                    editingControls
                }
                Spacer()
            }
        }
        .padding(10)
    }

    /// Insert/delete row plus Apply/Discard, shown only while editing is allowed.
    private var editingControls: some View {
        HStack(spacing: 8) {
            Button {
                browser.pending.addInsertedRow()
            } label: {
                Image(systemName: "plus")
            }
            .help("Insert row")
            Button {
                browser.deleteDisplayRows(browser.selectedDisplayRows)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(browser.selectedDisplayRows.isEmpty)
            .help("Delete selected row(s)")
            if !browser.pending.isEmpty {
                Button("Apply…") {
                    do {
                        applyPreview = SQLApplyPreview(
                            statements: try browser.buildApplyStatements())
                    } catch {
                        browser.applyState = .failed(String(describing: error))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(browser.applyState == .applying)
                .help("Review and apply pending changes")
                Button("Discard") {
                    browser.discardChanges()
                }
                .help("Throw away all pending changes")
            }
        }
    }

    private var columnsMenu: some View {
        Menu {
            Button("All Columns") {
                browser.requestNavigation {
                    browser.selectedColumns = []
                    browser.load()
                }
            }
            Divider()
            ForEach(browser.availableColumns, id: \.name) { column in
                Toggle(isOn: Binding(
                    get: {
                        browser.selectedColumns.isEmpty
                            || browser.selectedColumns.contains(column.name)
                    },
                    set: { _ in
                        browser.requestNavigation {
                            // Deselecting from "all" state keeps the others selected.
                            if browser.selectedColumns.isEmpty {
                                browser.selectedColumns = Set(
                                    browser.availableColumns.map(\.name))
                            }
                            browser.toggleColumn(column.name)
                            browser.load()
                        }
                    }
                )) {
                    Text("\(column.name)  –  \(column.dbTypeName)")
                }
            }
        } label: {
            Label(columnsLabel, systemImage: "slider.horizontal.3")
        }
        .frame(maxWidth: 220)
    }

    private var columnsLabel: String {
        if browser.selectedColumns.isEmpty {
            return "All columns"
        }
        return "\(browser.selectedColumns.count) of \(browser.availableColumns.count) columns"
    }

    private var statusBar: some View {
        HStack {
            if let error = browser.columnsError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            switch browser.resultTab.runState {
            case .idle:
                Text("Ready")
            case .running, .streaming:
                ProgressView().controlSize(.small)
                Text("Loading…")
            case .done(let count, let elapsed):
                Text("Rows \(browser.offset)–\(browser.offset + count) · \(String(format: "%.2f", elapsed))s")
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                Text("Cancelled").foregroundStyle(.orange)
            }
            switch browser.applyState {
            case .idle:
                if !browser.pending.isEmpty {
                    Label(browser.pending.summary, systemImage: "pencil")
                        .foregroundStyle(.orange)
                }
            case .applying:
                ProgressView().controlSize(.small)
                Text("Applying…")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            // Explain why cells aren't editable once data is on screen.
            if browser.descriptor.supportsTableEditing,
               case .done = browser.resultTab.runState,
               let reason = browser.editingDisabledReason {
                Label(reason, systemImage: "pencil.slash")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ExportStatusView(tab: browser.resultTab)
            ResultsViewModePicker(
                selection: $viewMode, columns: browser.resultTab.columns)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

/// Pre-apply confirmation: the exact SQL that will run, in order, in one
/// transaction. Literal encoding makes this preview byte-for-byte truthful.
private struct ApplyPreviewSheet: View {
    let statements: [String]
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "\(statements.count) statement\(statements.count == 1 ? "" : "s") will run in one transaction",
                systemImage: "checklist")
                .font(.headline)
            ScrollView {
                Text(statements.joined(separator: ";\n\n") + ";")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    dismiss()
                    onApply()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 300)
    }
}
