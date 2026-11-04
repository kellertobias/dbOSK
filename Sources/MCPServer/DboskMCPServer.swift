import Foundation
import Logging
import MCP

/// The app-facing facade: owns the HTTP transport, which runs one MCP
/// `Server` per client session. Read-only by construction — see `MCPToolbox`
/// for the tool surface and the gates behind it.
public actor DboskMCPServer {
    private let provider: any MCPConnectionProvider
    private let logger: Logger
    private var transport: HTTPServerTransport?

    public init(
        provider: any MCPConnectionProvider,
        logger: Logger = Logger(label: "dbosk.mcp")
    ) {
        self.provider = provider
        self.logger = logger
    }

    /// Starts the server on 127.0.0.1. Pass `port: 0` to bind an ephemeral
    /// port (tests). `token: nil` disables authentication.
    /// - Returns: the actually bound port.
    @discardableResult
    public func start(port: Int, token: String?) async throws -> Int {
        if let transport, let bound = await transport.boundPort { return bound }

        let version = appVersion()
        let toolbox = MCPToolbox(provider: provider, logger: logger)
        let transport = HTTPServerTransport(port: port, token: token, logger: logger) {
            session in
            let server = Server(
                name: "dbosk",
                version: version,
                capabilities: .init(tools: .init(listChanged: false)))
            await toolbox.register(on: server)
            try await server.start(transport: session)
            return server
        }
        try await transport.start()

        guard let bound = await transport.boundPort else {
            await transport.stop()
            throw MCPError.internalError("MCP server failed to bind a port")
        }
        self.transport = transport
        return bound
    }

    public func stop() async {
        await transport?.stop()
        transport = nil
    }

    public var isRunning: Bool { transport != nil }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
