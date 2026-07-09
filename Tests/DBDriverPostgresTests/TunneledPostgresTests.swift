import Connections
import DBCore
import Foundation
import Testing

@testable import DBDriverPostgres

/// End-to-end: query the docker Postgres through the docker SSH bastion.
/// Enable with: DBOSK_SSH_TESTS=1 (needs `docker compose --profile ssh up -d ssh postgres`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBOSK_SSH_TESTS"] == "1"))
struct TunneledPostgresTests {
    @Test func queriesPostgresThroughTunnel() async throws {
        let key = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/test_tunnel_key").path

        let tunnel = try await SSHTunnel.start(
            config: SSHTunnelConfig(
                host: "localhost", port: 22022, user: "tunnel",
                identityFile: key,
                extraOptions: [
                    "UserKnownHostsFile=/dev/null", "StrictHostKeyChecking=no",
                ]),
            // The bastion resolves the compose-internal service name.
            targetHost: "postgres", targetPort: 5432)
        defer { tunnel.stop() }

        let driver = try PostgresDriver(config: ResolvedConnectionConfig(
            host: "127.0.0.1",
            port: tunnel.localPort,
            user: "dbosk",
            password: "dbosk",
            database: "dbosk_test",
            tls: .disabled))
        try await driver.connect()

        let execution = try await driver.execute(
            .sql("SELECT 'via tunnel' AS proof"), pageSize: 10)
        var rows: [ResultRow] = []
        for try await chunk in execution.chunks {
            rows.append(contentsOf: chunk.rows)
        }
        #expect(rows.count == 1)
        #expect(rows[0].values[0] == .string("via tunnel"))
        await driver.disconnect()
    }
}
