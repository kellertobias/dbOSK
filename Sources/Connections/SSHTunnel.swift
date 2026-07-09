import DBCore
import Foundation

/// SSH tunnel settings stored on a connection profile. Authentication is
/// key-based only in v1: the ssh agent / default keys, or an explicit
/// identity file. (BatchMode disables interactive password prompts.)
public struct SSHTunnelConfig: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    public var user: String
    /// Path to a private key; nil uses the agent / default identities.
    public var identityFile: String?
    /// Extra `-o` options, mainly for tests (e.g. UserKnownHostsFile=/dev/null).
    public var extraOptions: [String]

    public init(
        host: String,
        port: Int = 22,
        user: String,
        identityFile: String? = nil,
        extraOptions: [String] = []
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.extraOptions = extraOptions
    }
}

public enum SSHTunnelError: Error, CustomStringConvertible {
    case noFreePort
    case processFailed(stderrTail: String)
    case timedOut(seconds: Double, stderrTail: String)

    public var description: String {
        switch self {
        case .noFreePort:
            return "Could not allocate a local port for the SSH tunnel"
        case .processFailed(let tail):
            return "SSH tunnel failed\(tail.isEmpty ? "" : ":\n\(tail)")"
        case .timedOut(let seconds, let tail):
            return "SSH tunnel did not come up within \(Int(seconds))s"
                + (tail.isEmpty ? "" : ":\n\(tail)")
        }
    }
}

/// A local-forward SSH tunnel backed by the system `ssh` binary, so the
/// user's ~/.ssh config, agent, and known_hosts all apply.
public final class SSHTunnel: @unchecked Sendable {
    public let localPort: Int
    private let process: Process
    private let stderrBuffer: StderrBuffer

    private init(localPort: Int, process: Process, stderrBuffer: StderrBuffer) {
        self.localPort = localPort
        self.process = process
        self.stderrBuffer = stderrBuffer
    }

    /// Builds the ssh argument list (separate for unit testing).
    public static func arguments(
        config: SSHTunnelConfig, localPort: Int, targetHost: String, targetPort: Int
    ) -> [String] {
        var args = [
            "-N",  // no remote command, forward only
            "-o", "BatchMode=yes",  // never prompt; fail instead
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-p", String(config.port),
            "-L", "127.0.0.1:\(localPort):\(targetHost):\(targetPort)",
        ]
        if let identity = config.identityFile, !identity.isEmpty {
            args += [
                "-i", (identity as NSString).expandingTildeInPath,
                "-o", "IdentitiesOnly=yes",
            ]
        }
        for option in config.extraOptions {
            args += ["-o", option]
        }
        args.append("\(config.user)@\(config.host)")
        return args
    }

    /// Picks a free localhost port by binding port 0 and reading the result.
    public static func findFreePort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw SSHTunnelError.noFreePort }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw SSHTunnelError.noFreePort }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else { throw SSHTunnelError.noFreePort }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    /// Starts the tunnel and waits until the forwarded port accepts
    /// connections (or ssh exits / the timeout passes).
    public static func start(
        config: SSHTunnelConfig,
        targetHost: String,
        targetPort: Int,
        timeout: TimeInterval = 15
    ) async throws -> SSHTunnel {
        let localPort = try findFreePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(
            config: config, localPort: localPort,
            targetHost: targetHost, targetPort: targetPort)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let stderrBuffer = StderrBuffer(pipe: stderr)

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                throw SSHTunnelError.processFailed(stderrTail: stderrBuffer.tail())
            }
            if canConnect(port: localPort) {
                return SSHTunnel(
                    localPort: localPort, process: process, stderrBuffer: stderrBuffer)
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        process.terminate()
        throw SSHTunnelError.timedOut(seconds: timeout, stderrTail: stderrBuffer.tail())
    }

    public func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Probing

    /// True if 127.0.0.1:port accepts a TCP connection right now.
    static func canConnect(port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var timeoutValue = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(
            socketFD, SOL_SOCKET, SO_SNDTIMEO,
            &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// Collects ssh stderr on a background reader so error states can show a tail.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    init(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.data.append(chunk)
            self.lock.unlock()
        }
    }

    func tail(bytes: Int = 2000) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data.suffix(bytes), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
