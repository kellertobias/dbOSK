import AppKit
import Connections
import DBCore
import DBDriverDynamoDB
import DBDriverMetabase
import DBDriverPostgres
import DBDriverSQLite
import SwiftUI

struct ConnectionListView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var editingProfile: ConnectionProfile?
    @State private var showingNewProfile = false

    /// Groups sorted by name; ungrouped connections come last.
    private var groupedProfiles: [(group: String?, profiles: [ConnectionProfile])] {
        let grouped = Dictionary(grouping: appModel.profiles) { $0.groupName }
        let named = grouped
            .filter { $0.key != nil }
            .sorted { ($0.key ?? "") < ($1.key ?? "") }
            .map { (group: $0.key, profiles: $0.value) }
        let ungrouped = grouped[nil].map { [(group: String?.none, profiles: $0)] } ?? []
        return named + ungrouped
    }

    var body: some View {
        @Bindable var appModel = appModel
        VStack(spacing: 0) {
            if appModel.profiles.isEmpty {
                WelcomeView(showingNewProfile: $showingNewProfile)
            } else {
                List {
                    ForEach(groupedProfiles, id: \.group) { section in
                        Section(section.group ?? "Connections") {
                            ForEach(section.profiles) { profile in
                                row(for: profile)
                            }
                        }
                    }
                }
            }
            if let error = appModel.connectionError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding()
            }
            if appModel.isConnecting {
                ProgressView().padding()
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            Button {
                showingNewProfile = true
            } label: {
                Label("New Connection", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingNewProfile) {
            ConnectionEditView(profile: nil)
        }
        .sheet(item: $editingProfile) { profile in
            ConnectionEditView(profile: profile)
        }
        // A connect hit an expired/missing Metabase session: run the SSO
        // login, store the fresh token, and retry the connect.
        .sheet(item: $appModel.metabaseLoginRequest) { profile in
            if let url = MetabaseURL.normalized(profile.host) {
                MetabaseLoginSheet(baseURL: url) { token in
                    appModel.metabaseLoginRequest = nil
                    do {
                        try appModel.keychain.setPassword(token, for: profile.id)
                    } catch {
                        // Reconnecting would reuse the old (rejected) token
                        // and loop right back into this sheet.
                        appModel.connectionError = """
                            Signed in, but the new session token could not be \
                            saved to the Keychain: \(error.localizedDescription)
                            """
                        return
                    }
                    Task {
                        if await appModel.connect(to: profile) {
                            openWindow(value: profile.id)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func row(for profile: ConnectionProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.headline)
                    if let label = appModel.label(for: profile) {
                        LabelBadge(label: label)
                    }
                }
                Text(subtitle(for: profile))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(appModel.sessions[profile.id] != nil ? "Open" : "Connect") {
                Task {
                    if await appModel.connect(to: profile) {
                        openWindow(value: profile.id)
                    }
                }
            }
            .disabled(appModel.isConnecting)
        }
        .contextMenu {
            Button("Edit…") { editingProfile = profile }
            Button("Delete", role: .destructive) { appModel.delete(profile) }
        }
    }

    private func subtitle(for profile: ConnectionProfile) -> String {
        var parts = [profile.driverID]
        if let host = profile.host {
            parts.append("\(host)\(profile.port.map { ":\($0)" } ?? "")")
        }
        if let database = profile.database { parts.append(database) }
        return parts.joined(separator: " · ")
    }
}

/// Shown in place of the connection list when there are no connections yet.
private struct WelcomeView: View {
    @Binding var showingNewProfile: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
                .grayscale(1)
                .opacity(0.35)
            VStack(spacing: 6) {
                Text("Welcome to dbOSK")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Create your first database connection to start")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                showingNewProfile = true
            } label: {
                Label("New Connection", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ConnectionEditView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let profile: ConnectionProfile?

    @State private var driverID = PostgresDriver.descriptor.id
    @State private var name = ""
    @State private var groupName = ""
    @State private var labelID: UUID?
    @State private var host = "localhost"
    @State private var port = ""
    @State private var user = ""
    @State private var database = ""
    @State private var tls: ResolvedConnectionConfig.TLSMode = .preferred
    @State private var credentialMode: CredentialMode = .password
    @State private var password = ""
    @State private var scriptPath = ""
    @State private var scriptArgs = ""
    @State private var awsProfile = ""
    @State private var awsRegion = ""
    @State private var awsSecretID = ""
    @State private var awsKeyHost = ""
    @State private var awsKeyPort = ""
    @State private var awsKeyUser = ""
    @State private var awsKeyPassword = ""
    @State private var awsKeyDatabase = ""
    @State private var awsFetchedKeys: [String] = []
    @State private var awsFetchStatus = ""
    @State private var awsFetchingKeys = false
    @State private var filePath = ""
    @State private var tunnelEnabled = false
    @State private var tunnelHost = ""
    @State private var tunnelPort = ""
    @State private var tunnelUser = ""
    @State private var tunnelIdentity = ""
    @State private var metabaseToken = ""
    @State private var metabaseHasStoredToken = false
    @State private var showingMetabaseLogin = false

    private var isFileBased: Bool { driverID == SQLiteDriver.descriptor.id }
    private var isMetabase: Bool { driverID == MetabaseDriver.descriptor.id }

    /// Whether the selected driver's connection can route through an SSH
    /// tunnel (false for HTTP-API drivers like Metabase).
    private var driverSupportsSSHTunnel: Bool {
        AppModel.availableDrivers
            .first { $0.id == driverID }?.supportsSSHTunnel ?? true
    }

    /// The Metabase base URL, when the host field normalizes to one (a bare
    /// host without scheme works — https:// is assumed).
    private var metabaseBaseURL: URL? {
        MetabaseURL.normalized(host)
    }

    enum CredentialMode: String, CaseIterable {
        case none = "None"
        case password = "Password"
        case script = "Script"
        case awsSecret = "AWS Secret"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile == nil ? "New Connection" : "Edit Connection")
                .font(.title2)

            Form {
                Picker("Database", selection: $driverID) {
                    ForEach(AppModel.availableDrivers, id: \.id) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
                TextField("Name", text: $name)
                HStack {
                    TextField("Group", text: $groupName, prompt: Text("Optional"))
                    if !existingGroups.isEmpty {
                        Menu {
                            ForEach(existingGroups, id: \.self) { group in
                                Button(group) { groupName = group }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                    }
                }
                LabeledContent("Label") {
                    HStack(spacing: 8) {
                        Picker("Label", selection: $labelID) {
                            Text("None").tag(UUID?.none)
                            ForEach(appModel.labels) { label in
                                Text(label.name).tag(UUID?.some(label.id))
                            }
                        }
                        .labelsHidden()
                        SettingsLink { Text("Manage…") }
                    }
                }
                if driverID == DynamoDBDriver.descriptor.id {
                    Text("""
                        DynamoDB: Host = AWS region (e.g. eu-central-1), \
                        User/Password = access key id and secret (leave empty \
                        for the default AWS credential chain). A URI from a \
                        credential script overrides the endpoint (dynamodb-local).
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isFileBased {
                    LabeledContent("File") {
                        HStack {
                            TextField(
                                "Path", text: $filePath,
                                prompt: Text("~/path/to/database.sqlite"))
                            Button("Choose…") { chooseFile() }
                        }
                    }
                } else if isMetabase {
                    // Metabase talks HTTPS to the instance URL and
                    // authenticates with a browser SSO session token, so the
                    // host/port/user/TLS/tunnel fields don't apply.
                    TextField(
                        "Metabase URL", text: $host,
                        prompt: Text("https://metabase.example.com"))
                    LabeledContent("Sign In") {
                        VStack(alignment: .leading, spacing: 4) {
                            Button(metabaseHasStoredToken
                                ? "Sign In Again…" : "Sign In with SSO…") {
                                showingMetabaseLogin = true
                            }
                            .disabled(metabaseBaseURL == nil)
                            // Freshly captured or already in the Keychain —
                            // either way a session token exists.
                            if !metabaseToken.isEmpty || metabaseHasStoredToken {
                                Text("Signed in — session token is stored in the Keychain.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    TextField("Host", text: $host)
                    TextField("Port", text: $port, prompt: Text(defaultPortPrompt))
                        .frame(maxWidth: 120)
                    TextField("User", text: $user)
                    TextField("Database", text: $database)
                    Picker("TLS", selection: $tls) {
                        ForEach(ResolvedConnectionConfig.TLSMode.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Picker("Credentials", selection: $credentialMode) {
                        ForEach(CredentialMode.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    switch credentialMode {
                    case .none:
                        EmptyView()
                    case .password:
                        SecureField("Password", text: $password)
                    case .script:
                        TextField("Script path", text: $scriptPath)
                        TextField("Arguments", text: $scriptArgs)
                        Text("The script must print JSON with host, port, user, password, database, or uri.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .awsSecret:
                        HStack {
                            TextField(
                                "AWS profile", text: $awsProfile,
                                prompt: Text("Default credential chain"))
                            if !awsProfiles.isEmpty {
                                Menu {
                                    ForEach(awsProfiles, id: \.self) { name in
                                        Button(name) { awsProfile = name }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 24)
                            }
                        }
                        TextField(
                            "Region", text: $awsRegion,
                            prompt: Text("From secret ARN or profile"))
                        TextField("Secret name or ARN", text: $awsSecretID)
                        LabeledContent("Secret keys") {
                            HStack {
                                Button(awsFetchingKeys ? "Fetching…" : "Fetch Keys") {
                                    fetchAWSKeys()
                                }
                                .disabled(awsSecretID.isEmpty || awsFetchingKeys)
                                if !awsFetchStatus.isEmpty {
                                    Text(awsFetchStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        if !awsKeyOptions.isEmpty {
                            awsKeyPicker("Host key", selection: $awsKeyHost)
                            awsKeyPicker("Port key", selection: $awsKeyPort)
                            awsKeyPicker("User key", selection: $awsKeyUser)
                            awsKeyPicker("Password key", selection: $awsKeyPassword)
                            awsKeyPicker("Database key", selection: $awsKeyDatabase)
                        }
                        Text("""
                            Uses your AWS credentials from ~/.aws — SSO profiles \
                            are supported (run `aws sso login` first). The secret \
                            supplies the password and fills in any of the fields \
                            above you leave empty; values you set here win over \
                            the secret's. "Auto" tries the standard RDS key names \
                            (host, port, username, password, dbname).
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Connect via SSH tunnel", isOn: $tunnelEnabled)
                    if tunnelEnabled {
                        TextField("SSH host", text: $tunnelHost)
                        TextField("SSH port", text: $tunnelPort, prompt: Text("22"))
                            .frame(maxWidth: 120)
                        TextField("SSH user", text: $tunnelUser)
                        HStack {
                            TextField(
                                "Identity file", text: $tunnelIdentity,
                                prompt: Text("Optional — uses agent/default keys"))
                            Button("Choose…") { chooseIdentityFile() }
                        }
                        Text("Key-based auth only (ssh agent or identity file); the database host/port above are reached from the SSH host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.isEmpty || (isFileBased && filePath.isEmpty)
                            || (isMetabase && host.isEmpty)
                            || (!isFileBased && !isMetabase
                                && credentialMode == .awsSecret
                                && awsSecretID.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { populate() }
        .sheet(isPresented: $showingMetabaseLogin) {
            if let url = metabaseBaseURL {
                MetabaseLoginSheet(baseURL: url) { token in
                    metabaseToken = token
                }
            }
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            tunnelIdentity = url.path
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            filePath = url.path
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }

    private var existingGroups: [String] {
        Array(Set(appModel.profiles.compactMap(\.groupName))).sorted()
    }

    private var awsProfiles: [String] { AWSConfigFile.profileNames() }

    /// Fetched keys plus any saved selections, so pickers render a previously
    /// configured mapping even before the secret is re-fetched.
    private var awsKeyOptions: [String] {
        let selected = [awsKeyHost, awsKeyPort, awsKeyUser, awsKeyPassword, awsKeyDatabase]
            .filter { !$0.isEmpty }
        return Array(Set(awsFetchedKeys + selected)).sorted()
    }

    private func awsKeyPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Auto").tag("")
            ForEach(awsKeyOptions, id: \.self) { key in
                Text(key).tag(key)
            }
        }
    }

    private func fetchAWSKeys() {
        awsFetchStatus = ""
        awsFetchingKeys = true
        let config = AWSSecretConfig(
            profileName: awsProfile.isEmpty ? nil : awsProfile,
            region: awsRegion.isEmpty ? nil : awsRegion,
            secretID: awsSecretID)
        Task {
            do {
                let keys = try await AWSSecretCredentialLoader().availableKeys(config)
                awsFetchedKeys = keys
                awsFetchStatus = keys.isEmpty
                    ? "Secret is a plain string — no keys to map."
                    : "Found \(keys.count) keys."
            } catch {
                awsFetchStatus = String(describing: error)
            }
            awsFetchingKeys = false
        }
    }

    private var defaultPortPrompt: String {
        let port = AppModel.availableDrivers
            .first { $0.id == driverID }?.defaultPort
        return port.map(String.init) ?? ""
    }

    private func populate() {
        guard let profile else { return }
        driverID = profile.driverID
        name = profile.name
        groupName = profile.groupName ?? ""
        labelID = profile.labelID
        host = profile.host ?? ""
        port = profile.port.map(String.init) ?? ""
        user = profile.user ?? ""
        database = profile.database ?? ""
        filePath = profile.filePath ?? ""
        tls = profile.tls
        switch profile.credentialSource {
        case .none:
            credentialMode = .none
        case .keychain:
            credentialMode = .password
            if profile.driverID == MetabaseDriver.descriptor.id {
                // The session token stays in the Keychain; the form only
                // needs to know whether one exists.
                metabaseHasStoredToken =
                    (try? appModel.keychain.password(for: profile.id))?.isEmpty == false
            } else {
                password = (try? appModel.keychain.password(for: profile.id)) ?? ""
            }
        case .script(let config):
            credentialMode = .script
            scriptPath = config.path
            scriptArgs = config.args.joined(separator: " ")
        case .awsSecretsManager(let config):
            credentialMode = .awsSecret
            awsProfile = config.profileName ?? ""
            awsRegion = config.region ?? ""
            awsSecretID = config.secretID
            awsKeyHost = config.keyMapping?.host ?? ""
            awsKeyPort = config.keyMapping?.port ?? ""
            awsKeyUser = config.keyMapping?.user ?? ""
            awsKeyPassword = config.keyMapping?.password ?? ""
            awsKeyDatabase = config.keyMapping?.database ?? ""
        }
        if let tunnel = profile.sshTunnel {
            tunnelEnabled = true
            tunnelHost = tunnel.host
            tunnelPort = tunnel.port == 22 ? "" : String(tunnel.port)
            tunnelUser = tunnel.user
            tunnelIdentity = tunnel.identityFile ?? ""
        }
    }

    private func save() {
        let source: CredentialSource
        switch credentialMode {
        case _ where isFileBased: source = .none
        // Metabase always keeps its session token in the Keychain.
        case _ where isMetabase: source = .keychain
        case .none: source = .none
        case .password: source = .keychain
        case .script:
            let args = scriptArgs.split(separator: " ").map(String.init)
            source = .script(ScriptConfig(path: scriptPath, args: args))
        case .awsSecret:
            let mapping = AWSSecretKeyMapping(
                host: awsKeyHost.isEmpty ? nil : awsKeyHost,
                port: awsKeyPort.isEmpty ? nil : awsKeyPort,
                user: awsKeyUser.isEmpty ? nil : awsKeyUser,
                password: awsKeyPassword.isEmpty ? nil : awsKeyPassword,
                database: awsKeyDatabase.isEmpty ? nil : awsKeyDatabase)
            source = .awsSecretsManager(
                AWSSecretConfig(
                    profileName: awsProfile.isEmpty ? nil : awsProfile,
                    region: awsRegion.isEmpty ? nil : awsRegion,
                    secretID: awsSecretID,
                    keyMapping: mapping.isEmpty ? nil : mapping))
        }
        let updated = ConnectionProfile(
            id: profile?.id ?? UUID(),
            name: name,
            groupName: groupName.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : groupName.trimmingCharacters(in: .whitespaces),
            labelID: labelID,
            driverID: driverID,
            host: isFileBased || host.isEmpty ? nil : host,
            port: isFileBased || isMetabase ? nil : Int(port),
            user: isFileBased || isMetabase || user.isEmpty ? nil : user,
            database: isFileBased || isMetabase || database.isEmpty ? nil : database,
            filePath: isFileBased && !filePath.isEmpty ? filePath : nil,
            tls: tls,
            credentialSource: source,
            sshTunnel: !isFileBased && driverSupportsSSHTunnel
                && tunnelEnabled && !tunnelHost.isEmpty
                ? SSHTunnelConfig(
                    host: tunnelHost,
                    port: Int(tunnelPort) ?? 22,
                    user: tunnelUser,
                    identityFile: tunnelIdentity.isEmpty ? nil : tunnelIdentity)
                : nil
        )
        // Metabase saves the freshly captured session token (if any); a save
        // without a new sign-in keeps whatever the Keychain already holds.
        let secret: String?
        if isMetabase {
            secret = metabaseToken.isEmpty ? nil : metabaseToken
        } else if !isFileBased && credentialMode == .password {
            secret = password
        } else {
            secret = nil
        }
        appModel.upsert(updated, password: secret)
        dismiss()
    }
}
