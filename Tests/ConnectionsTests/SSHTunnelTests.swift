import DBCore
import Foundation
import Testing

@testable import Connections

@Suite struct SSHTunnelUnitTests {
    @Test func buildsArguments() {
        let config = SSHTunnelConfig(
            host: "bastion.example.com", port: 2222, user: "deploy",
            identityFile: "~/.ssh/id_deploy")
        let args = SSHTunnel.arguments(
            config: config, localPort: 50123,
            targetHost: "db.internal", targetPort: 5432)

        #expect(args.contains("-N"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ExitOnForwardFailure=yes"))
        #expect(args.contains("127.0.0.1:50123:db.internal:5432"))
        #expect(args.contains("2222"))
        #expect(args.contains("IdentitiesOnly=yes"))
        #expect(args.last == "deploy@bastion.example.com")
        // Tilde must be expanded for -i.
        let identityIndex = args.firstIndex(of: "-i")!
        #expect(args[identityIndex + 1].hasPrefix("/"))
    }

    @Test func omitsIdentityWhenUnset() {
        let args = SSHTunnel.arguments(
            config: SSHTunnelConfig(host: "h", user: "u"),
            localPort: 50000, targetHost: "t", targetPort: 1)
        #expect(!args.contains("-i"))
        #expect(!args.contains("IdentitiesOnly=yes"))
    }

    @Test func findsDistinctFreePorts() throws {
        let first = try SSHTunnel.findFreePort()
        #expect((1024...65535).contains(first))
    }

    @Test func failsFastOnUnreachableHost() async {
        // Port 1 on localhost: connection refused immediately -> ssh exits.
        let config = SSHTunnelConfig(
            host: "127.0.0.1", port: 1, user: "nobody",
            extraOptions: ["UserKnownHostsFile=/dev/null"])
        await #expect(throws: SSHTunnelError.self) {
            _ = try await SSHTunnel.start(
                config: config, targetHost: "db", targetPort: 5432, timeout: 10)
        }
    }

    @Test func profileRoundtripsTunnelConfig() throws {
        let profile = ConnectionProfile(
            name: "tunneled", driverID: "postgres", host: "db.internal",
            sshTunnel: SSHTunnelConfig(
                host: "bastion", port: 2222, user: "deploy",
                identityFile: "/keys/id"))
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        #expect(decoded.sshTunnel == profile.sshTunnel)

        // Profiles without a tunnel stay nil (backward compatibility).
        let plain = ConnectionProfile(name: "plain", driverID: "postgres")
        let plainDecoded = try JSONDecoder().decode(
            ConnectionProfile.self, from: try JSONEncoder().encode(plain))
        #expect(plainDecoded.sshTunnel == nil)
    }
}

/// Integration test against the docker ssh bastion (port 22022) forwarding
/// to the docker postgres. Enable with: DBOSK_SSH_TESTS=1 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBOSK_SSH_TESTS"] == "1"))
struct SSHTunnelIntegrationTests {
    private static var fixtureKey: String {
        // Tests/Fixtures/test_tunnel_key relative to this file.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ConnectionsTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/test_tunnel_key").path
    }

    @Test func forwardsTCPThroughBastion() async throws {
        let config = SSHTunnelConfig(
            host: "localhost",
            port: 22022,
            user: "tunnel",
            identityFile: Self.fixtureKey,
            extraOptions: ["UserKnownHostsFile=/dev/null", "StrictHostKeyChecking=no"])

        // "postgres:5432" is resolved by the bastion inside the compose network.
        let tunnel = try await SSHTunnel.start(
            config: config, targetHost: "postgres", targetPort: 5432)
        defer { tunnel.stop() }

        #expect(SSHTunnel.canConnect(port: tunnel.localPort))
    }

    @Test func wrongKeyFailsWithStderr() async throws {
        let config = SSHTunnelConfig(
            host: "localhost",
            port: 22022,
            user: "tunnel",
            identityFile: nil,  // agent won't have the test key
            extraOptions: [
                "UserKnownHostsFile=/dev/null", "StrictHostKeyChecking=no",
                "IdentityAgent=none", "IdentitiesOnly=yes",
            ])
        await #expect(throws: SSHTunnelError.self) {
            _ = try await SSHTunnel.start(
                config: config, targetHost: "postgres", targetPort: 5432, timeout: 10)
        }
    }
}
