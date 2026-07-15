import Foundation
import Testing

@testable import Dbosk

@Suite struct ClaudeInstallerTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-config-\(UUID().uuidString).json")
    }

    private func json(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    @Test func createsMissingConfig() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try ClaudeInstaller.merge(
            server: ["type": "http", "url": "http://127.0.0.1:52814/mcp"], into: url)

        let root = try json(at: url)
        let servers = root["mcpServers"] as? [String: Any]
        let dbosk = servers?["dbosk"] as? [String: Any]
        #expect(dbosk?["url"] as? String == "http://127.0.0.1:52814/mcp")
    }

    @Test func preservesExistingKeysAndServers() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let existing: [String: Any] = [
            "numStartups": 42,
            "theme": "dark",
            "mcpServers": [
                "other": ["type": "stdio", "command": "other-server"],
                "dbosk": ["type": "http", "url": "http://old:1/mcp"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: url)

        try ClaudeInstaller.merge(
            server: ["type": "http", "url": "http://127.0.0.1:9999/mcp"], into: url)

        let root = try json(at: url)
        #expect(root["numStartups"] as? Int == 42)
        #expect(root["theme"] as? String == "dark")
        let servers = root["mcpServers"] as? [String: Any]
        #expect((servers?["other"] as? [String: Any])?["command"] as? String == "other-server")
        #expect((servers?["dbosk"] as? [String: Any])?["url"] as? String
            == "http://127.0.0.1:9999/mcp")
    }

    @Test func refusesToClobberInvalidJSON() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json {{".utf8).write(to: url)

        #expect(throws: ClaudeInstaller.InstallError.self) {
            try ClaudeInstaller.merge(server: ["url": "x"], into: url)
        }
        // Original content untouched.
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json {{")
    }
}
