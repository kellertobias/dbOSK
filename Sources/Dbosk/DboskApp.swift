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
            LabelSettingsView()
                .environment(appModel)
        }
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
