import Foundation
import Logging
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix

/// Streamable-HTTP server transport for the MCP `Server`: a loopback-only
/// NIOHTTP1 listener where each `POST /mcp` carries one JSON-RPC message and
/// receives its paired response (stateless mode — the server never pushes,
/// so no SSE stream is needed; `GET` answers 405).
///
/// Bridging model: request bodies are yielded into the `receive()` stream the
/// MCP `Server` consumes; the server's `send(_:)` looks up the pending HTTP
/// exchange by JSON-RPC id and completes it. Notifications (no id) answer
/// 202 immediately.
public actor HTTPServerTransport: Transport {
    public nonisolated let logger: Logger

    private let host: String
    private let requestedPort: Int
    /// Bearer token; nil disables authentication (user setting).
    private let token: String?

    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var stream: AsyncThrowingStream<Data, Error>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    /// Pending HTTP exchanges keyed by JSON-RPC id rendering.
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]

    public private(set) var boundPort: Int?

    public init(
        host: String = "127.0.0.1", port: Int, token: String?,
        logger: Logger = Logger(label: "dbosk.mcp.transport")
    ) {
        self.host = host
        self.requestedPort = port
        self.token = token
        self.logger = logger
    }

    // MARK: Transport conformance

    public func connect() async throws {
        guard channel == nil else { return }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        self.stream = stream
        self.continuation = continuation

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
            self.stream = nil
            self.continuation = nil
            throw MCPError.transportError(error)
        }
    }

    public func disconnect() async {
        continuation?.finish()
        continuation = nil
        stream = nil
        for (_, waiter) in pending {
            waiter.resume(throwing: MCPError.internalError("Server stopped"))
        }
        pending.removeAll()
        try? await channel?.close()
        channel = nil
        if let group {
            try? await group.shutdownGracefully()
        }
        group = nil
        boundPort = nil
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
        case response(Data)
        /// Notification (no id): 202, no body.
        case accepted
        /// Malformed JSON / unsupported batch.
        case badRequest(String)
    }

    /// Feeds one HTTP request body to the MCP server and waits for the
    /// paired response.
    func dispatch(body: Data) async -> Exchange {
        guard let continuation else {
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

        guard let id = Self.render(id: object["id"]) else {
            continuation.yield(body)
            return .accepted
        }

        do {
            let response = try await withCheckedThrowingContinuation { waiter in
                pending[id] = waiter
                continuation.yield(body)
            }
            return .response(response)
        } catch {
            return .badRequest(String(describing: error))
        }
    }

    /// Renders a JSON-RPC id (number or string) to a stable dictionary key.
    private static func render(id: Any?) -> String? {
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
        guard head.method == .POST else {
            // Stateless server: no SSE stream to offer on GET.
            respond(
                context: context, status: .methodNotAllowed, body: "Use POST",
                keepAlive: keepAlive)
            return
        }

        let requestBody = body.getData(at: 0, length: body.readableBytes) ?? Data()
        let channel = context.channel
        let transport = self.transport
        // Bridge to the actor off the event loop; the channel is written from
        // the task via thread-safe Channel methods.
        Task {
            switch await transport.dispatch(body: requestBody) {
            case .response(let data):
                Self.write(
                    status: .ok, payload: data, contentType: "application/json",
                    to: channel, keepAlive: keepAlive)
            case .accepted:
                Self.write(
                    status: .accepted, payload: Data(), contentType: "text/plain",
                    to: channel, keepAlive: keepAlive)
            case .badRequest(let message):
                Self.write(
                    status: .badRequest, payload: Data(message.utf8),
                    contentType: "text/plain", to: channel, keepAlive: keepAlive)
            }
        }
    }

    private static func write(
        status: HTTPResponseStatus, payload: Data, contentType: String,
        to channel: Channel, keepAlive: Bool
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(payload.count)")
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
