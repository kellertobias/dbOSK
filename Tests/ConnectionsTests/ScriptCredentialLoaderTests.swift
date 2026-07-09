import Foundation
import Testing

@testable import Connections

@Suite struct ScriptCredentialLoaderTests {
    private func makeScript(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cred.sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func parsesValidJSON() async throws {
        let path = try makeScript(
            #"echo '{"user": "ada", "password": "s3cret", "port": 5433}'"#)
        let creds = try await ScriptCredentialLoader().load(ScriptConfig(path: path))
        #expect(creds.user == "ada")
        #expect(creds.password == "s3cret")
        #expect(creds.port == 5433)
        #expect(creds.uri == nil)
    }

    @Test func surfacesStderrOnFailure() async throws {
        let path = try makeScript("echo 'vault is sealed' >&2; exit 3")
        await #expect {
            _ = try await ScriptCredentialLoader().load(ScriptConfig(path: path))
        } throws: { error in
            guard case ScriptCredentialError.nonZeroExit(let code, let tail) = error
            else { return false }
            return code == 3 && tail.contains("vault is sealed")
        }
    }

    @Test func rejectsInvalidJSON() async throws {
        let path = try makeScript("echo 'not json'")
        await #expect(throws: ScriptCredentialError.self) {
            _ = try await ScriptCredentialLoader().load(ScriptConfig(path: path))
        }
    }

    @Test func missingScript() async {
        await #expect(throws: ScriptCredentialError.self) {
            _ = try await ScriptCredentialLoader().load(
                ScriptConfig(path: "/nonexistent/script.sh"))
        }
    }

    @Test func timesOut() async throws {
        let path = try makeScript("sleep 30")
        await #expect {
            _ = try await ScriptCredentialLoader().load(
                ScriptConfig(path: path, timeoutSeconds: 0.5))
        } throws: { error in
            guard case ScriptCredentialError.timedOut = error else { return false }
            return true
        }
    }
}
