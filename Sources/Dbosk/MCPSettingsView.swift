import AppKit
import Connections
import DBCore
import SwiftUI

/// Preferences tab for the local MCP server: lifecycle and transport
/// settings, client install helpers, and the per-connection access list.
struct MCPSettingsView: View {
    @Environment(AppModel.self) private var appModel

    @AppStorage(MCPServerController.enabledKey) private var enabled = false
    @AppStorage(MCPServerController.portKey) private var port = MCPServerController.defaultPort
    @AppStorage(MCPServerController.authRequiredKey) private var authRequired = true

    @State private var revealToken = false
    @State private var installSheet: InstallInstructions?
    @State private var showConnectionSettings = false
    @State private var configuringProfile: ConnectionProfile?

    private var controller: MCPServerController { appModel.mcp }

    var body: some View {
        Form {
            serverSection
            Divider().padding(.vertical, 4)
            installSection
            Divider().padding(.vertical, 4)
            connectionsSection
        }
        .padding(20)
        .frame(width: 560)
        .sheet(item: $installSheet) { instructions in
            InstallInstructionsSheet(instructions: instructions)
        }
        .sheet(item: $configuringProfile) { profile in
            AllowlistSheet(
                profile: profile,
                session: appModel.sessions[profile.id],
                controller: controller)
        }
    }

    // MARK: Server

    @ViewBuilder private var serverSection: some View {
        Toggle("Enable MCP server", isOn: $enabled)
            .onChange(of: enabled) { _, isOn in
                isOn ? controller.start() : controller.stop()
            }
        Text("Exposes enabled connections to MCP clients on this Mac. "
            + "Only read-only queries are possible: writes, DDL, and "
            + "session changes are blocked.")
            .font(.caption)
            .foregroundStyle(.secondary)

        LabeledContent("Status") {
            switch controller.state {
            case .stopped: Text("Stopped").foregroundStyle(.secondary)
            case .starting: Text("Starting…").foregroundStyle(.secondary)
            case .running(let port):
                Label("Running on 127.0.0.1:\(String(port))", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }

        TextField("Port", value: $port, format: .number.grouping(.never))
            .frame(maxWidth: 160)
            .onSubmit { controller.restartIfRunning() }

        Toggle("Require authentication", isOn: $authRequired)
            .onChange(of: authRequired) { _, _ in controller.restartIfRunning() }
        if authRequired {
            LabeledContent("Bearer token") {
                HStack(spacing: 8) {
                    Text(revealToken ? controller.token() : String(repeating: "•", count: 24))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Button(revealToken ? "Hide" : "Show") { revealToken.toggle() }
                    Button("Copy") { copyToPasteboard(controller.token()) }
                    Button("Regenerate") { controller.regenerateToken() }
                }
            }
        } else {
            Text("Without authentication, every process on this Mac can query "
                + "the allowed connections.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Install helpers

    @ViewBuilder private var installSection: some View {
        HStack {
            Menu("Install MCP") {
                Button("Install in Claude") { installInClaude() }
                Button("Install in Cursor") { openCursorDeepLink() }
                Button("Install in ChatGPT") { installSheet = chatGPTInstructions }
                Button("Install in OpenCode") { installSheet = openCodeInstructions }
            }
            .frame(maxWidth: 160)

            Button("Show Connection Settings") { showConnectionSettings.toggle() }
        }
        Text("“Install in Claude” writes the server into Claude Code's and "
            + "Claude Desktop's MCP configuration directly; “Install in "
            + "Cursor” opens Cursor's install dialog; the others show "
            + "step-by-step instructions.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if let feedback = controller.installFeedback {
            Label(feedback.text, systemImage: feedback.isError
                ? "exclamationmark.triangle" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(feedback.isError ? Color.orange : Color.green)
                .transition(.opacity)
        }

        if showConnectionSettings {
            LabeledContent("Endpoint") {
                Text(controller.endpointURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("Transport") { Text("Streamable HTTP (POST)") }
            if authRequired {
                LabeledContent("Header") {
                    HStack {
                        Text("Authorization: Bearer \(revealToken ? controller.token() : "•••")")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Button("Copy") {
                            copyToPasteboard("Authorization: Bearer \(controller.token())")
                        }
                    }
                }
            }
        }
    }

    private var claudeCommand: String {
        var command = "claude mcp add --scope user --transport http dbosk \(controller.endpointURL)"
        if authRequired {
            command += " --header \"Authorization: Bearer \(controller.token())\""
        }
        return command
    }

    /// Writes the server into Claude Code's (`~/.claude.json`, via the CLI
    /// when available) and Claude Desktop's (`claude_desktop_config.json`)
    /// MCP configuration. The clipboard command is only the failure fallback.
    private func installInClaude() {
        let endpoint = controller.endpointURL
        let token = authRequired ? controller.token() : nil
        let fallbackCommand = claudeCommand
        let controller = self.controller
        controller.showInstallFeedback("Configuring Claude…")
        Task {
            let outcome = await ClaudeInstaller.install(
                endpoint: endpoint, bearerToken: token)
            var parts: [String] = []
            if !outcome.configured.isEmpty {
                parts.append(
                    "Configured \(outcome.configured.joined(separator: " and ")). "
                    + "Restart running sessions to pick it up.")
            }
            if !outcome.failures.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fallbackCommand, forType: .string)
                parts.append(
                    outcome.failures.joined(separator: " · ")
                    + " — the install command was copied to the clipboard; "
                    + "paste it into a terminal instead.")
            }
            if parts.isEmpty {
                parts.append("Neither Claude Code nor Claude Desktop was found on this Mac.")
            }
            controller.showInstallFeedback(
                parts.joined(separator: " "), isError: !outcome.failures.isEmpty)
        }
    }

    private func openCursorDeepLink() {
        var config: [String: Any] = ["url": controller.endpointURL]
        if authRequired {
            config["headers"] = ["Authorization": "Bearer \(controller.token())"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: config),
            var components = URLComponents(string: "cursor://anysphere.cursor-deeplink/mcp/install")
        else { return }
        components.queryItems = [
            URLQueryItem(name: "name", value: "dbosk"),
            URLQueryItem(name: "config", value: data.base64EncodedString()),
        ]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            controller.showInstallFeedback(
                "Cursor doesn't seem to be installed — use “Show Connection "
                + "Settings” to configure it manually.", isError: true)
            return
        }
        controller.showInstallFeedback(
            "Opening Cursor — confirm the “Install MCP server” dialog there.")
    }

    private var chatGPTInstructions: InstallInstructions {
        InstallInstructions(
            title: "Install in ChatGPT",
            steps: [
                "ChatGPT connects to MCP servers via connectors (Settings → Connectors → Advanced → Developer mode).",
                "Add a new connector and paste the endpoint URL below.",
                authRequired
                    ? "Add the Authorization header shown below."
                    : "No authentication header is needed.",
                "Note: ChatGPT's connectors run from OpenAI's servers, which cannot reach 127.0.0.1 on this Mac. This works only with clients that run locally; consider Claude, Cursor, or OpenCode for local access.",
            ],
            fields: installFields)
    }

    private var openCodeInstructions: InstallInstructions {
        var mcpEntry: [String: Any] = ["type": "remote", "url": controller.endpointURL]
        if authRequired {
            mcpEntry["headers"] = ["Authorization": "Bearer \(controller.token())"]
        }
        let config: [String: Any] = ["mcp": ["dbosk": mcpEntry]]
        let json = (try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return InstallInstructions(
            title: "Install in OpenCode",
            steps: [
                "Merge the snippet below into ~/.config/opencode/opencode.json (or the project's opencode.json).",
                "Restart OpenCode; the dbOSK tools appear once the server is running.",
            ],
            fields: [InstallInstructions.Field(label: "opencode.json", value: json)])
    }

    private var installFields: [InstallInstructions.Field] {
        var fields = [InstallInstructions.Field(label: "Endpoint", value: controller.endpointURL)]
        if authRequired {
            fields.append(.init(
                label: "Header",
                value: "Authorization: Bearer \(controller.token())"))
        }
        return fields
    }

    // MARK: Connections

    @ViewBuilder private var connectionsSection: some View {
        Text("Connections").font(.headline)
        Text("MCP clients can only reach connections that are active in dbOSK "
            + "and enabled here. Restrict each connection to selected tables "
            + "if needed.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if appModel.profiles.isEmpty {
            Text("No connections configured yet.")
                .foregroundStyle(.secondary)
        }
        ForEach(appModel.profiles) { profile in
            connectionRow(profile)
        }
    }

    @ViewBuilder private func connectionRow(_ profile: ConnectionProfile) -> some View {
        let access = controller.access(for: profile.id)
        let isActive = appModel.sessions[profile.id] != nil
        HStack {
            Toggle(isOn: Binding(
                get: { controller.access(for: profile.id).enabled },
                set: { isOn in
                    var config = controller.access(for: profile.id)
                    config.enabled = isOn
                    controller.setAccess(config, for: profile.id)
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                    Text(isActive ? "Connected" : "Not connected — connect to expose it")
                        .font(.caption2)
                        .foregroundStyle(isActive ? Color.green : Color.secondary)
                }
            }
            Spacer()
            if access.enabled {
                Picker("", selection: Binding(
                    get: { scopeIsAllTables(access) },
                    set: { allTables in
                        var config = controller.access(for: profile.id)
                        config.scope = allTables ? .allTables : existingAllowlist(config)
                        controller.setAccess(config, for: profile.id)
                    }
                )) {
                    Text("All tables").tag(true)
                    Text(allowlistLabel(access)).tag(false)
                }
                .frame(maxWidth: 170)
                .labelsHidden()
                if !scopeIsAllTables(access) {
                    Button("Configure…") { configuringProfile = profile }
                }
            }
        }
    }

    private func scopeIsAllTables(_ access: MCPAccessConfig) -> Bool {
        if case .allTables = access.scope { return true }
        return false
    }

    private func existingAllowlist(_ access: MCPAccessConfig) -> MCPAccessConfig.Scope {
        if case .allowlist = access.scope { return access.scope }
        return .allowlist([])
    }

    private func allowlistLabel(_ access: MCPAccessConfig) -> String {
        if case .allowlist(let entries) = access.scope {
            return "Selected (\(entries.count))"
        }
        return "Selected tables"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Install instructions sheet

struct InstallInstructions: Identifiable {
    struct Field: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let title: String
    let steps: [String]
    let fields: [Field]
    var id: String { title }
}

private struct InstallInstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let instructions: InstallInstructions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(instructions.title).font(.title3.bold())
            ForEach(Array(instructions.steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ForEach(instructions.fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(field.label).font(.caption.bold())
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(field.value, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    Text(field.value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Allowlist configuration sheet

/// Tree of the connection's namespaces with a checkbox per node; checking a
/// database/schema allows everything beneath it. Uses the live session's
/// sidebar data, loading children on expand.
private struct AllowlistSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ConnectionProfile
    let session: ConnectionSession?
    let controller: MCPServerController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allowed tables for “\(profile.name)”").font(.title3.bold())
            Text("MCP queries may only read checked namespaces. Checking a "
                + "schema or database allows all tables beneath it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(session.rootNamespaces) { namespace in
                            AllowlistNodeView(
                                namespace: namespace, session: session,
                                profileID: profile.id, controller: controller,
                                depth: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 260, maxHeight: 380)
                .task { await session.loadRoot() }
            } else {
                ContentUnavailableView(
                    "Not connected", systemImage: "bolt.slash",
                    description: Text("Connect to “\(profile.name)” to browse its "
                        + "tables. Existing allowlist entries are kept."))
                    .frame(minHeight: 200)
            }

            HStack {
                Text(entriesSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var entriesSummary: String {
        if case .allowlist(let entries) = controller.access(for: profile.id).scope {
            return "\(entries.count) allowed \(entries.count == 1 ? "entry" : "entries")"
        }
        return ""
    }
}

private struct AllowlistNodeView: View {
    // SwiftUI also declares `Namespace`; qualify the DBCore model type.
    let namespace: DBCore.Namespace
    let session: ConnectionSession
    let profileID: UUID
    let controller: MCPServerController
    let depth: Int

    @State private var expanded = false

    var body: some View {
        HStack(spacing: 4) {
            if namespace.isExpandable {
                Button {
                    expanded.toggle()
                    if expanded {
                        Task { await session.loadChildren(of: namespace) }
                    }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 16)
            }
            Toggle(isOn: binding) {
                Label(namespace.name, systemImage: icon)
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 18)

        if expanded {
            let children = session.children[namespace.id] ?? []
            if children.isEmpty {
                Text("Loading…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, CGFloat(depth + 1) * 18 + 16)
            }
            ForEach(children) { child in
                AllowlistNodeView(
                    namespace: child, session: session, profileID: profileID,
                    controller: controller, depth: depth + 1)
            }
        }
    }

    private var icon: String {
        switch namespace.kind {
        case .database: return "cylinder"
        case .schema: return "folder"
        case .table: return "tablecells"
        }
    }

    /// Checked when this exact path (or an ancestor) is allowlisted.
    private var binding: Binding<Bool> {
        Binding(
            get: {
                let access = controller.access(for: profileID)
                guard case .allowlist = access.scope else { return false }
                return access.allowsReading(path: namespace.path)
            },
            set: { isOn in
                var access = controller.access(for: profileID)
                var entries: [[String]]
                if case .allowlist(let existing) = access.scope {
                    entries = existing
                } else {
                    entries = []
                }
                let path = namespace.path
                if isOn {
                    if !entries.contains(path) { entries.append(path) }
                } else {
                    // Remove this entry and any entries beneath it.
                    entries.removeAll { entry in
                        entry.count >= path.count
                            && Array(entry.prefix(path.count)).map { $0.lowercased() }
                                == path.map { $0.lowercased() }
                    }
                }
                access.scope = .allowlist(entries)
                controller.setAccess(access, for: profileID)
            })
    }
}
