import Connections
import Foundation
import MCPServer
import Observation
import Security

/// Owns the MCP server lifecycle and its user-facing configuration:
/// enabled/port/auth settings (UserDefaults), the bearer token (Keychain),
/// and the per-profile access map (MCPAccessStore JSON).
@Observable
@MainActor
final class MCPServerController {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    static let enabledKey = "mcpServerEnabled"
    static let portKey = "mcpServerPort"
    static let authRequiredKey = "mcpServerAuthRequired"
    static let defaultPort = 52814

    struct InstallFeedback: Equatable {
        let text: String
        let isError: Bool
    }

    private(set) var state: State = .stopped
    /// Transient status line under the Install button ("Configured Claude
    /// Code…"). Owned here rather than as view @State: the auto-dismiss task
    /// must not outlive a view struct or touch its state off-actor.
    private(set) var installFeedback: InstallFeedback?
    /// Bumped when settings change so views re-render derived snippets.
    private(set) var accessMap: [UUID: MCPAccessConfig]
    @ObservationIgnored private var feedbackDismissal: Task<Void, Never>?

    private let accessStore = MCPAccessStore()
    private let keychain: KeychainStore
    private var server: DboskMCPServer?
    private var provider: (any MCPConnectionProvider)?
    /// Serializes start/stop so a quick toggle can't interleave them.
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?

    init(keychain: KeychainStore) {
        self.keychain = keychain
        self.accessMap = accessStore.load()
    }

    /// Late wiring: the provider references AppModel, which owns this
    /// controller, so it is injected after both exist.
    func configure(provider: any MCPConnectionProvider) {
        self.provider = provider
    }

    // MARK: Settings

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var port: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        return stored == 0 ? Self.defaultPort : stored
    }

    var authRequired: Bool {
        UserDefaults.standard.object(forKey: Self.authRequiredKey) == nil
            ? true  // secure default
            : UserDefaults.standard.bool(forKey: Self.authRequiredKey)
    }

    var endpointURL: String {
        let boundPort: Int
        if case .running(let port) = state { boundPort = port } else { boundPort = port }
        return "http://127.0.0.1:\(boundPort)/mcp"
    }

    // MARK: Token

    /// Returns the persistent bearer token, minting one on first use.
    func token() -> String {
        if let existing = try? keychain.mcpToken(), !existing.isEmpty {
            return existing
        }
        let fresh = Self.randomToken()
        try? keychain.setMCPToken(fresh)
        return fresh
    }

    func regenerateToken() {
        try? keychain.setMCPToken(Self.randomToken())
        restartIfRunning()
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Install feedback

    func showInstallFeedback(_ text: String, isError: Bool = false) {
        installFeedback = InstallFeedback(text: text, isError: isError)
        feedbackDismissal?.cancel()
        let shown = installFeedback
        feedbackDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.installFeedback == shown else { return }
            self.installFeedback = nil
        }
    }

    // MARK: Access map

    func access(for profileID: UUID) -> MCPAccessConfig {
        accessMap[profileID] ?? MCPAccessConfig()
    }

    func setAccess(_ config: MCPAccessConfig, for profileID: UUID) {
        accessMap[profileID] = config
        try? accessStore.save(accessMap)
    }

    // MARK: Lifecycle

    func startIfEnabled() {
        if enabled { start() }
    }

    func start() {
        guard let provider else { return }
        let port = self.port
        let token = authRequired ? token() : nil
        enqueue { [weak self] in
            guard let self else { return }
            if self.server != nil { return }
            self.state = .starting
            let server = DboskMCPServer(provider: provider)
            do {
                let bound = try await server.start(port: port, token: token)
                self.server = server
                self.state = .running(port: bound)
            } catch {
                self.state = .failed(String(describing: error))
            }
        }
    }

    func stop() {
        enqueue { [weak self] in
            guard let self else { return }
            await self.server?.stop()
            self.server = nil
            if case .failed = self.state { return }
            self.state = .stopped
        }
    }

    /// Applies changed settings (port, auth) to a running server.
    func restartIfRunning() {
        guard server != nil || state == .starting else { return }
        stop()
        start()
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = lifecycleTask
        lifecycleTask = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }
}
