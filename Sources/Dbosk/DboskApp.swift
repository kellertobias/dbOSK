import AppKit
import SwiftUI

@main
struct DboskApp: App {
    @State private var appModel = AppModel()

    init() {
        // When launched as a bare executable (swift run) there is no app bundle,
        // so AppKit starts us as a background process: windows can't become key
        // and text fields won't accept input. Force regular-app behavior.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // Launcher window with the connection list.
        Window("Connections", id: "connections") {
            ConnectionListView()
                .environment(appModel)
        }
        .windowToolbarStyle(.unified)

        // One window per live connection; native window tabbing applies.
        WindowGroup(for: UUID.self) { $profileID in
            SessionWindowView(profileID: profileID)
                .environment(appModel)
        }
        .windowToolbarStyle(.unified)

        // Preferences (⌘,) — define the labels connections can carry.
        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                LabelSettingsView()
                    .tabItem { Label("Labels", systemImage: "tag") }
                MCPSettingsView()
                    .tabItem { Label("MCP", systemImage: "server.rack") }
            }
            .environment(appModel)
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage(QueryTab.pageSizeDefaultsKey) private var pageSize = 500

    var body: some View {
        Form {
            Picker("Fetch chunk size", selection: $pageSize) {
                ForEach([100, 250, 500, 1000, 5000], id: \.self) { size in
                    Text("\(size) rows").tag(size)
                }
            }
            .frame(maxWidth: 280)
            Text("How many rows are fetched per chunk while streaming results. Applies to newly opened tabs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct SessionWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID?

    var body: some View {
        if let profileID, let session = appModel.sessions[profileID] {
            SessionView(session: session)
        } else {
            ContentUnavailableView(
                "Disconnected", systemImage: "bolt.slash",
                description: Text("This connection was closed."))
                .onAppear {
                    // Window restored without a live session — close it.
                    if profileID == nil { dismiss() }
                }
        }
    }
}
