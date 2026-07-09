import SwiftUI

@main
struct DboskApp: App {
    @State private var appModel = AppModel()

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
