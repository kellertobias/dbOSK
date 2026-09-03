import DBCore
import Foundation

/// Output schema of a credential script. All keys optional; values are merged
/// over the profile's fields. `uri` wins over everything when present.
/// `authenticationDatabase` (alias `authSource`) is the MongoDB auth database.
public struct ScriptCredentials: Codable, Sendable {
    public var host: String?
    public var port: Int?
    public var user: String?
    public var password: String?
    public var database: String?
    public var authenticationDatabase: String?
    public var uri: String?

    private enum CodingKeys: String, CodingKey {
        case host, port, user, password, database, authenticationDatabase, uri
        case authSource  // decode-only alias for authenticationDatabase
    }

    public init(
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        password: String? = nil,
        database: String? = nil,
        authenticationDatabase: String? = nil,
        uri: String? = nil
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.authenticationDatabase = authenticationDatabase
        self.uri = uri
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        database = try c.decodeIfPresent(String.self, forKey: .database)
        authenticationDatabase =
            try c.decodeIfPresent(String.self, forKey: .authenticationDatabase)
            ?? c.decodeIfPresent(String.self, forKey: .authSource)
        uri = try c.decodeIfPresent(String.self, forKey: .uri)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(user, forKey: .user)
        try c.encodeIfPresent(password, forKey: .password)
        try c.encodeIfPresent(database, forKey: .database)
        try c.encodeIfPresent(authenticationDatabase, forKey: .authenticationDatabase)
        try c.encodeIfPresent(uri, forKey: .uri)
    }
}

public enum ScriptCredentialError: Error, CustomStringConvertible {
    case scriptNotFound(String)
    case timedOut(seconds: Double)
    case nonZeroExit(code: Int32, stderrTail: String)
    case invalidJSON(String, stdoutPreview: String)

    public var description: String {
        switch self {
        case .scriptNotFound(let path):
            return "Credential script not found: \(path)"
        case .timedOut(let seconds):
            return "Credential script timed out after \(Int(seconds))s"
        case .nonZeroExit(let code, let stderrTail):
            let detail = stderrTail.isEmpty ? "" : "\n\(stderrTail)"
            return "Credential script exited with status \(code)\(detail)"
        case .invalidJSON(let message, let stdoutPreview):
            let detail = stdoutPreview.isEmpty ? "" : "\nOutput: \(stdoutPreview)"
            return "Credential script did not print valid JSON: \(message)\(detail)"
        }
    }
}

/// Runs a user-provided executable and parses its stdout as JSON credentials.
/// The script path is executed directly (no shell); users who need shell
/// features point the profile at a wrapper script.
public struct ScriptCredentialLoader: Sendable {
    public init() {}

    public func load(_ config: ScriptConfig) async throws -> ScriptCredentials {
        let path = (config.path as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ScriptCredentialError.scriptNotFound(path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = config.args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Drain pipes off the calling task so a chatty script can't deadlock on
        // a full pipe buffer.
        async let stdoutData = readToEnd(stdout)
        async let stderrData = readToEnd(stderr)

        let timedOut = await waitWithTimeout(process, seconds: config.timeoutSeconds)
        let outData = await stdoutData
        let errData = await stderrData

        if timedOut {
            throw ScriptCredentialError.timedOut(seconds: config.timeoutSeconds)
        }
        guard process.terminationStatus == 0 else {
            let tail = String(data: errData.suffix(2000), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ScriptCredentialError.nonZeroExit(
                code: process.terminationStatus, stderrTail: tail)
        }
        do {
            return try JSONDecoder().decode(ScriptCredentials.self, from: outData)
        } catch {
            // Never log full stdout — it likely contains a secret. A short,
            // user-facing preview only when decoding failed outright.
            let preview = outData.isEmpty ? "(empty)" : "(\(outData.count) bytes, not shown)"
            throw ScriptCredentialError.invalidJSON(
                "\(error.localizedDescription)", stdoutPreview: preview)
        }
    }

    private func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }

    /// Returns true if the process had to be killed due to timeout.
    private func waitWithTimeout(_ process: Process, seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            let done = OnceLatch()
            process.terminationHandler = { _ in
                if done.take() { continuation.resume(returning: false) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard done.take() else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                continuation.resume(returning: true)
            }
        }
    }
}

/// Tiny once-latch: first `take()` returns true, all later calls false.
private final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
