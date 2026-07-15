import Foundation

/// Configures dbOSK's MCP server in Claude's own configuration files:
///
/// - **Claude Code**: via `claude mcp add --scope user` when the CLI is
///   installed (keeps us aligned with whatever schema the CLI writes), with
///   a direct merge into `~/.claude.json` → `mcpServers` as fallback.
/// - **Claude Desktop**: merged into
///   `~/Library/Application Support/Claude/claude_desktop_config.json`.
///   The desktop config only launches stdio servers, so the HTTP endpoint is
///   bridged through `npx mcp-remote`. The auth header is passed via an env
///   var (`Authorization:${DBOSK_MCP_AUTH}`) because Claude Desktop
///   mis-parses argument values containing spaces.
///
/// All file work runs off the main actor; results come back as an `Outcome`
/// the settings UI turns into user feedback.
enum ClaudeInstaller {

    struct Outcome: Sendable {
        var configured: [String] = []
        var failures: [String] = []
    }

    static func install(endpoint: String, bearerToken: String?) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            var outcome = Outcome()

            do {
                try installClaudeCode(endpoint: endpoint, bearerToken: bearerToken)
                outcome.configured.append("Claude Code (user scope)")
            } catch {
                outcome.failures.append("Claude Code: \(shortDescription(error))")
            }

            switch installClaudeDesktop(endpoint: endpoint, bearerToken: bearerToken) {
            case .configured:
                outcome.configured.append("Claude Desktop")
            case .notInstalled:
                break  // nothing to configure, not a failure
            case .failed(let message):
                outcome.failures.append("Claude Desktop: \(message)")
            }
            return outcome
        }.value
    }

    // MARK: - Claude Code

    private nonisolated static func installClaudeCode(
        endpoint: String, bearerToken: String?
    ) throws {
        if let binary = claudeBinaryPath() {
            // Remove first so a changed port or regenerated token updates
            // cleanly; `mcp add` refuses to overwrite an existing entry.
            _ = run(binary: binary, arguments: ["mcp", "remove", "--scope", "user", "dbosk"])
            var arguments = [
                "mcp", "add", "--scope", "user", "--transport", "http", "dbosk", endpoint,
            ]
            if let bearerToken {
                arguments += ["--header", "Authorization: Bearer \(bearerToken)"]
            }
            if run(binary: binary, arguments: arguments).exitCode == 0 { return }
            // CLI misbehaved — fall through to the direct config merge.
        }

        var server: [String: Any] = ["type": "http", "url": endpoint]
        if let bearerToken {
            server["headers"] = ["Authorization": "Bearer \(bearerToken)"]
        }
        try merge(
            server: server,
            into: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json"))
    }

    private nonisolated static func claudeBinaryPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func run(
        binary: String, arguments: [String]
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Claude Desktop

    private enum DesktopResult {
        case configured, notInstalled, failed(String)
    }

    private nonisolated static func installClaudeDesktop(
        endpoint: String, bearerToken: String?
    ) -> DesktopResult {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude")
        let appInstalled = FileManager.default.fileExists(atPath: "/Applications/Claude.app")
        guard appInstalled
            || FileManager.default.fileExists(atPath: supportDirectory.path)
        else { return .notInstalled }

        var arguments = ["-y", "mcp-remote", endpoint]
        var server: [String: Any] = ["command": "npx"]
        if let bearerToken {
            // No space after the colon on purpose: Claude Desktop splits
            // argument values on spaces (documented mcp-remote workaround).
            arguments += ["--header", "Authorization:${DBOSK_MCP_AUTH}"]
            server["env"] = ["DBOSK_MCP_AUTH": "Bearer \(bearerToken)"]
        }
        server["args"] = arguments

        do {
            try FileManager.default.createDirectory(
                at: supportDirectory, withIntermediateDirectories: true)
            try merge(
                server: server,
                into: supportDirectory.appendingPathComponent("claude_desktop_config.json"))
            return .configured
        } catch {
            return .failed(shortDescription(error))
        }
    }

    // MARK: - Shared

    struct InstallError: Error, CustomStringConvertible {
        let description: String
    }

    /// Merges `mcpServers.dbosk = server` into a JSON config file, keeping
    /// everything else in the file untouched. Creates the file if missing;
    /// refuses to overwrite a file it cannot parse. Internal for tests.
    nonisolated static func merge(server: [String: Any], into fileURL: URL) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                let object = parsed as? [String: Any]
            else {
                throw InstallError(description:
                    "\(fileURL.lastPathComponent) exists but is not valid JSON; "
                    + "not overwriting it.")
            }
            root = object
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["dbosk"] = server
        root["mcpServers"] = servers

        let output = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func shortDescription(_ error: Error) -> String {
        if let installError = error as? InstallError { return installError.description }
        return String(describing: error)
    }
}
