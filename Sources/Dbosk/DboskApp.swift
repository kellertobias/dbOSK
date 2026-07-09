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
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let session = appModel.activeSession {
            SessionView(session: session)
        } else {
            ConnectionListView()
        }
    }
}
