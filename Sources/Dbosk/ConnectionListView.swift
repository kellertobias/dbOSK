import Connections
import DBCore
import DBDriverPostgres
import SwiftUI

struct ConnectionListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var editingProfile: ConnectionProfile?
    @State private var showingNewProfile = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(appModel.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(profile.name).font(.headline)
                            Text(subtitle(for: profile))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") {
                            Task { await appModel.connect(to: profile) }
                        }
                        .disabled(appModel.isConnecting)
                    }
                    .contextMenu {
                        Button("Edit…") { editingProfile = profile }
                        Button("Delete", role: .destructive) { appModel.delete(profile) }
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
        .frame(minWidth: 480, minHeight: 320)
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

struct ConnectionEditView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let profile: ConnectionProfile?

    @State private var driverID = PostgresDriver.descriptor.id
    @State private var name = ""
    @State private var host = "localhost"
    @State private var port = ""
    @State private var user = ""
    @State private var database = ""
    @State private var tls: ResolvedConnectionConfig.TLSMode = .preferred
    @State private var credentialMode: CredentialMode = .password
    @State private var password = ""
    @State private var scriptPath = ""
    @State private var scriptArgs = ""

    enum CredentialMode: String, CaseIterable {
        case none = "None"
        case password = "Password"
        case script = "Script"
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
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { populate() }
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
        host = profile.host ?? ""
        port = profile.port.map(String.init) ?? ""
        user = profile.user ?? ""
        database = profile.database ?? ""
        tls = profile.tls
        switch profile.credentialSource {
        case .none:
            credentialMode = .none
        case .keychain:
            credentialMode = .password
            password = (try? appModel.keychain.password(for: profile.id)) ?? ""
        case .script(let config):
            credentialMode = .script
            scriptPath = config.path
            scriptArgs = config.args.joined(separator: " ")
        }
    }

    private func save() {
        let source: CredentialSource
        switch credentialMode {
        case .none: source = .none
        case .password: source = .keychain
        case .script:
            let args = scriptArgs.split(separator: " ").map(String.init)
            source = .script(ScriptConfig(path: scriptPath, args: args))
        }
        let updated = ConnectionProfile(
            id: profile?.id ?? UUID(),
            name: name,
            driverID: driverID,
            host: host.isEmpty ? nil : host,
            port: Int(port),
            user: user.isEmpty ? nil : user,
            database: database.isEmpty ? nil : database,
            tls: tls,
            credentialSource: source
        )
        appModel.upsert(updated, password: credentialMode == .password ? password : nil)
        dismiss()
    }
}
