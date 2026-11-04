import Foundation
import Logging
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix

/// Streamable-HTTP endpoint for MCP: a loopback-only NIOHTTP1 listener where
/// each `POST /mcp` carries one JSON-RPC message and receives its paired
/// response (the server never pushes, so no SSE stream is needed; `GET`
/// answers 405).
///
/// Sessions: every `initialize` gets a fresh MCP `Server` and an
/// `Mcp-Session-Id` response header. The SDK's `Server` accepts `initialize`
/// only once per instance, so one shared server would refuse every client
/// after the first ("Server is already initialized") — reconnects, a second
/// Claude Code session, Claude Desktop. Requests carrying the header are
/// routed to their session; an unknown id answers 404 so the client
/// re-initializes, and `DELETE` ends a session. Requests without the header
/// share one default session, which keeps header-less clients working (the
/// server does not enforce initialization).
public actor HTTPServerTransport {
    public nonisolated let logger: Logger

    /// Builds a `Server` and starts it on the given session transport.
    public typealias SessionFactory = @Sendable (SessionTransport) async throws -> Server

    /// Response/request header carrying the session id.
    static let sessionHeader = "Mcp-Session-Id"
    /// Live sessions beyond this close the least recently used one, so
    /// reconnect loops cannot pile up servers.
    static let maxSessions = 16

    private let host: String
    private let requestedPort: Int
    /// Bearer token; nil disables authentication (user setting).
    private let token: String?
    private let makeSession: SessionFactory

    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    /// Sessions opened by `initialize`, keyed by session id.
    private var sessions: [String: Session] = [:]
    /// Serves requests without a session header; nil once stopped.
    private var defaultSession: Session?

    public private(set) var boundPort: Int?

    private struct Session {
        let server: Server
        let transport: SessionTransport
        var lastUsed: ContinuousClock.Instant
    }

    public init(
        host: String = "127.0.0.1", port: Int, token: String?,
        logger: Logger = Logger(label: "dbosk.mcp.transport"),
        makeSession: @escaping SessionFactory
    ) {
        self.host = host
        self.requestedPort = port
        self.token = token
        self.logger = logger
        self.makeSession = makeSession
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard channel == nil else { return }
        defaultSession = try await openSession()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandler(
                        MCPHTTPHandler(transport: self))
                }
            }
        do {
            let channel = try await bootstrap.bind(host: host, port: requestedPort).get()
            self.channel = channel
            boundPort = channel.localAddress?.port
            logger.info("MCP server listening", metadata: ["port": "\(boundPort ?? -1)"])
        } catch {
            try? await group.shutdownGracefully()
            self.group = nil
            await stopSessions()
            throw MCPError.transportError(error)
        }
    }

    public func stop() async {
        await stopSessions()
        try? await channel?.close()
        channel = nil
        if let group {
            try? await group.shutdownGracefully()
        }
        group = nil
        boundPort = nil
    }

    private func openSession() async throws -> Session {
        let transport = SessionTransport(logger: logger)
        let server = try await makeSession(transport)
        return Session(server: server, transport: transport, lastUsed: .now)
    }

    private func stopSessions() async {
        var all = Array(sessions.values)
        if let defaultSession { all.append(defaultSession) }
        sessions.removeAll()
        defaultSession = nil
        for session in all {
            await session.server.stop()
        }
    }

    private func evictIfNeeded() async {
        while sessions.count > Self.maxSessions,
            let oldest = sessions.min(by: { $0.value.lastUsed < $1.value.lastUsed })
        {
            sessions.removeValue(forKey: oldest.key)
            logger.info("Closing least recently used MCP session")
            await oldest.value.server.stop()
        }
    }

    // MARK: HTTP exchange bridging (called from the channel handler)

    /// Validates the Authorization header. Constant-time comparison.
    nonisolated func authorized(header: String?) -> Bool {
        guard let token else { return true }
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let presented = Array(String(header.dropFirst("Bearer ".count)).utf8)
        let expected = Array(token.utf8)
        guard presented.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(presented, expected) { difference |= a ^ b }
        return difference == 0
    }

    enum Exchange {
        /// Request with an id: hold the HTTP response for the paired reply.
        /// `sessionID` is set when the request opened a session.
        case response(Data, sessionID: String?)
        /// Notification (no id): 202, no body.
        case accepted
        /// Malformed JSON / unsupported batch.
        case badRequest(String)
        /// Session id unknown or already closed: 404, client re-initializes.
        case unknownSession
    }

    /// Feeds one HTTP request body to the MCP server of its session and
    /// waits for the paired response.
    func dispatch(body: Data, sessionID: String?) async -> Exchange {
        guard let defaultSession else {
            return .badRequest("Server is shutting down")
        }
        guard let json = try? JSONSerialization.jsonObject(with: body),
            let object = json as? [String: Any]
        else {
            if (try? JSONSerialization.jsonObject(with: body)) is [Any] {
                return .badRequest("JSON-RPC batch messages are not supported")
            }
            return .badRequest("Body must be a single JSON-RPC message")
        }
        let id = SessionTransport.render(id: object["id"])

        if object["method"] as? String == "initialize" {
            let session: Session
            do {
                session = try await openSession()
            } catch {
                return .badRequest("Could not open MCP session: \(error)")
            }
            // stop() may have run while the session was starting.
            guard self.defaultSession != nil else {
                await session.server.stop()
                return .badRequest("Server is shutting down")
            }
            let sessionID = UUID().uuidString
            sessions[sessionID] = session
            await evictIfNeeded()
            let exchange = await session.transport.dispatch(body: body, id: id)
            if case .response(let data, _) = exchange {
                return .response(data, sessionID: sessionID)
            }
            return exchange
        }

        guard let sessionID else {
            return await defaultSession.transport.dispatch(body: body, id: id)
        }
        guard var session = sessions[sessionID] else { return .unknownSession }
        session.lastUsed = .now
        sessions[sessionID] = session
        return await session.transport.dispatch(body: body, id: id)
    }

    /// Ends a session on the client's `DELETE`. Returns false if unknown.
    func terminate(sessionID: String) async -> Bool {
        guard let session = sessions.removeValue(forKey: sessionID) else { return false }
        await session.server.stop()
        return true
    }
}

/// The transport one MCP `Server` runs on, one per session. Request bodies
/// are yielded into the `receive()` stream the server consumes; the server's
/// `send(_:)` looks up the pending HTTP exchange by JSON-RPC id and completes
/// it. Ids only need to be unique within a session, so two clients both
/// sending id 1 no longer collide. Notifications (no id) answer 202
/// immediately.
public actor SessionTransport: Transport {
    public nonisolated let logger: Logger

    private var stream: AsyncThrowingStream<Data, Error>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    /// Pending HTTP exchanges keyed by JSON-RPC id rendering.
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]

    init(logger: Logger) {
        self.logger = logger
    }

    // MARK: Transport conformance

    public func connect() async throws {
        guard continuation == nil else { return }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        self.stream = stream
        self.continuation = continuation
    }

    public func disconnect() async {
        continuation?.finish()
        continuation = nil
        stream = nil
        for (_, waiter) in pending {
            waiter.resume(throwing: MCPError.internalError("Server stopped"))
        }
        pending.removeAll()
    }

    public func send(_ data: Data) async throws {
        guard let id = Self.messageID(in: data) else {
            // Server-initiated notification; stateless mode has no channel
            // for it, drop with a log line.
            logger.debug("Dropping server message without id (stateless HTTP)")
            return
        }
        if let waiter = pending.removeValue(forKey: id) {
            waiter.resume(returning: data)
        } else {
            logger.warning("No pending HTTP exchange for response id \(id)")
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        if let stream { return stream }
        return AsyncThrowingStream { $0.finish() }
    }

    // MARK: Bridging

    /// Feeds one JSON-RPC message (already validated, `id` rendered) to the
    /// server and waits for the paired response.
    func dispatch(body: Data, id: String?) async -> HTTPServerTransport.Exchange {
        guard let continuation else {
            return .badRequest("Server is shutting down")
        }
        guard let id else {
            continuation.yield(body)
            return .accepted
        }

        do {
            let response = try await withCheckedThrowingContinuation { waiter in
                pending[id] = waiter
                continuation.yield(body)
            }
            return .response(response, sessionID: nil)
        } catch {
            return .badRequest(String(describing: error))
        }
    }

    /// Renders a JSON-RPC id (number or string) to a stable dictionary key.
    static func render(id: Any?) -> String? {
        switch id {
        case let number as NSNumber: return "n:\(number)"
        case let string as String: return "s:\(string)"
        default: return nil
        }
    }

    private static func messageID(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
            let object = json as? [String: Any]
        else { return nil }
        return render(id: object["id"])
    }
}

// MARK: - Channel handler

/// Per-connection HTTP handler: aggregates a request, checks path/method/
/// auth, then bridges the body through the transport actor.
private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let transport: HTTPServerTransport
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    /// Requests above this size are certainly not legitimate tool calls.
    private static let maxBodyBytes = 4 * 1024 * 1024

    init(transport: HTTPServerTransport) {
        self.transport = transport
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.clear()
        case .body(var buffer):
            if body.readableBytes + buffer.readableBytes > Self.maxBodyBytes {
                respond(
                    context: context, status: .payloadTooLarge, body: "Request body too large",
                    keepAlive: false)
                head = nil
                return
            }
            body.writeBuffer(&buffer)
        case .end:
            guard let head else { return }
            self.head = nil
            handle(context: context, head: head)
        }
    }

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let keepAlive = head.isKeepAlive

        guard path == "/mcp" else {
            respond(context: context, status: .notFound, body: "Not found", keepAlive: keepAlive)
            return
        }
        guard transport.authorized(header: head.headers.first(name: "Authorization")) else {
            respond(
                context: context, status: .unauthorized,
                body: "Missing or invalid bearer token", keepAlive: keepAlive)
            return
        }

        let sessionID = head.headers.first(name: HTTPServerTransport.sessionHeader)
        let channel = context.channel
        let transport = self.transport

        if head.method == .DELETE {
            guard let sessionID else {
                respond(
                    context: context, status: .badRequest,
                    body: "Missing \(HTTPServerTransport.sessionHeader) header",
                    keepAlive: keepAlive)
                return
            }
            Task {
                let ended = await transport.terminate(sessionID: sessionID)
                Self.write(
                    status: ended ? .ok : .notFound, payload: Data(), contentType: "text/plain",
                    to: channel, keepAlive: keepAlive)
            }
            return
        }
        guard head.method == .POST else {
            // No SSE stream to offer on GET.
            respond(
                context: context, status: .methodNotAllowed, body: "Use POST",
                keepAlive: keepAlive)
            return
        }

        let requestBody = body.getData(at: 0, length: body.readableBytes) ?? Data()
        // Bridge to the actor off the event loop; the channel is written from
        // the task via thread-safe Channel methods.
        Task {
            switch await transport.dispatch(body: requestBody, sessionID: sessionID) {
            case .response(let data, let newSessionID):
                Self.write(
                    status: .ok, payload: data, contentType: "application/json",
                    sessionID: newSessionID, to: channel, keepAlive: keepAlive)
            case .accepted:
                Self.write(
                    status: .accepted, payload: Data(), contentType: "text/plain",
                    to: channel, keepAlive: keepAlive)
            case .badRequest(let message):
                Self.write(
                    status: .badRequest, payload: Data(message.utf8),
                    contentType: "text/plain", to: channel, keepAlive: keepAlive)
            case .unknownSession:
                Self.write(
                    status: .notFound, payload: Data("Unknown or expired MCP session".utf8),
                    contentType: "text/plain", to: channel, keepAlive: keepAlive)
            }
        }
    }

    private static func write(
        status: HTTPResponseStatus, payload: Data, contentType: String,
        sessionID: String? = nil, to channel: Channel, keepAlive: Bool
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(payload.count)")
        if let sessionID { headers.add(name: HTTPServerTransport.sessionHeader, value: sessionID) }
        if !keepAlive { headers.add(name: "Connection", value: "close") }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        let end = channel.writeAndFlush(HTTPServerResponsePart.end(nil))
        if !keepAlive {
            end.whenComplete { _ in channel.close(promise: nil) }
        }
    }

    private func respond(
        context: ChannelHandlerContext, status: HTTPResponseStatus, body: String,
        keepAlive: Bool
    ) {
        Self.write(
            status: status, payload: Data(body.utf8), contentType: "text/plain",
            to: context.channel, keepAlive: keepAlive)
    }
}
