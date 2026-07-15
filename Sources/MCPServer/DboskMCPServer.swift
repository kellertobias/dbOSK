import Foundation
import Logging
import MCP

/// The app-facing facade: owns the MCP `Server` and its HTTP transport.
/// Read-only by construction — see `MCPToolbox` for the tool surface and the
/// gates behind it.
public actor DboskMCPServer {
    private let provider: any MCPConnectionProvider
    private let logger: Logger
    private var server: Server?
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

        let transport = HTTPServerTransport(port: port, token: token, logger: logger)
        let server = Server(
            name: "dbosk",
            version: appVersion(),
            capabilities: .init(tools: .init(listChanged: false)))
        await MCPToolbox(provider: provider, logger: logger).register(on: server)
        try await server.start(transport: transport)

        guard let bound = await transport.boundPort else {
            await server.stop()
            throw MCPError.internalError("MCP server failed to bind a port")
        }
        self.server = server
        self.transport = transport
        return bound
    }

    public func stop() async {
        await server?.stop()
        server = nil
        transport = nil
    }

    public var isRunning: Bool { server != nil }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
