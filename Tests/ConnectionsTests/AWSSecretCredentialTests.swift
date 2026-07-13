import DBCore
import Foundation
import Testing

@testable import Connections

@Suite struct AWSSecretPayloadTests {
    @Test func parsesRDSStyleSecret() {
        let payload = AWSSecretPayload.parse(
            secretString: """
                {"username": "admin", "password": "hunter2", "engine": "postgres",
                 "host": "db.example.com", "port": 5432, "dbname": "app"}
                """)
        #expect(payload.user == "admin")
        #expect(payload.password == "hunter2")
        #expect(payload.host == "db.example.com")
        #expect(payload.port == 5432)
        #expect(payload.database == "app")
        #expect(payload.uri == nil)
    }

    @Test func parsesAliasKeysAndStringPort() {
        let payload = AWSSecretPayload.parse(
            secretString: """
                {"user": "bob", "password": "pw", "hostname": "h", "port": "3306",
                 "database": "d"}
                """)
        #expect(payload.user == "bob")
        #expect(payload.host == "h")
        #expect(payload.port == 3306)
        #expect(payload.database == "d")
    }

    @Test func prefersCanonicalKeysOverAliases() {
        let payload = AWSSecretPayload.parse(
            secretString: #"{"username": "canonical", "user": "alias"}"#)
        #expect(payload.user == "canonical")
    }

    @Test func plainStringSecretBecomesPassword() {
        let payload = AWSSecretPayload.parse(secretString: "just-a-password")
        #expect(payload.password == "just-a-password")
        #expect(payload.host == nil)
        #expect(payload.user == nil)
    }

    @Test func keyMappingOverridesAliases() {
        let payload = AWSSecretPayload.parse(
            secretString: """
                {"db_endpoint": "custom.host", "db_user": "u", "pass": "pw",
                 "host": "alias-host", "username": "alias-user", "listen": "3307"}
                """,
            mapping: AWSSecretKeyMapping(
                host: "db_endpoint", port: "listen", user: "db_user", password: "pass"))
        #expect(payload.host == "custom.host")
        #expect(payload.port == 3307)
        #expect(payload.user == "u")
        #expect(payload.password == "pw")
        // database is unmapped → alias fallback (absent here)
        #expect(payload.database == nil)
    }

    @Test func mappedKeyMissingFromSecretYieldsNilNotAlias() {
        let payload = AWSSecretPayload.parse(
            secretString: #"{"host": "alias-host", "password": "pw"}"#,
            mapping: AWSSecretKeyMapping(host: "db_endpoint"))
        #expect(payload.host == nil)
        #expect(payload.password == "pw")
    }

    @Test func mappedNumericValueIsStringified() {
        let payload = AWSSecretPayload.parse(
            secretString: #"{"db": 42, "password": "pw"}"#,
            mapping: AWSSecretKeyMapping(database: "db"))
        #expect(payload.database == "42")
    }

    @Test func keyMappingRoundTripsInProfile() throws {
        let profile = ConnectionProfile(
            name: "mapped",
            driverID: "mysql",
            credentialSource: .awsSecretsManager(
                AWSSecretConfig(
                    secretID: "s",
                    keyMapping: AWSSecretKeyMapping(host: "db_endpoint", password: "pass")))
        )
        let data = try JSONEncoder().encode([profile])
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: data)
        #expect(decoded == [profile])
    }

    @Test func recordsPresentKeysWithoutValues() {
        let payload = AWSSecretPayload.parse(
            secretString: #"{"username": "u", "password": "pw", "engine": "mysql"}"#)
        #expect(payload.presentKeys == ["engine", "password", "username"])
        #expect(payload.diagnosticsSummary.contains("engine, password, username"))
        #expect(!payload.diagnosticsSummary.contains("pw"))

        let plain = AWSSecretPayload.parse(secretString: "just-a-password")
        #expect(plain.presentKeys == nil)
        #expect(plain.diagnosticsSummary.contains("plain"))
        #expect(!plain.diagnosticsSummary.contains("just-a-password"))
    }

    @Test func fillingAttachesDiagnostics() {
        let payload = AWSSecretPayload.parse(
            secretString: #"{"password": "pw", "host": "h"}"#)
        let merged = payload.filling(ResolvedConnectionConfig())
        #expect(merged.credentialDiagnostics?.contains("host, password") == true)
    }

    @Test func profileFieldsWinOverSecretValues() {
        let payload = AWSSecretPayload(
            host: "internal.vpc.local", port: 3306, user: "secret-user",
            password: "pw", database: "secret-db")
        let config = ResolvedConnectionConfig(
            host: "tunnel.example.com", port: 13306, user: "me", database: "app")
        let merged = payload.filling(config)
        #expect(merged.host == "tunnel.example.com")
        #expect(merged.port == 13306)
        #expect(merged.user == "me")
        #expect(merged.database == "app")
        #expect(merged.password == "pw")
        #expect(merged.uri == nil)
    }

    @Test func secretFillsFieldsTheProfileLeftEmpty() {
        let payload = AWSSecretPayload(
            host: "db.internal", port: 5432, user: "app", password: "pw",
            database: "prod")
        let merged = payload.filling(ResolvedConnectionConfig())
        #expect(merged.host == "db.internal")
        #expect(merged.port == 5432)
        #expect(merged.user == "app")
        #expect(merged.database == "prod")
        #expect(merged.password == "pw")
    }

    @Test func secretURIIsIgnoredWhenProfileSetsHost() {
        let payload = AWSSecretPayload(password: "pw", uri: "postgres://u:p@h/db")
        let withHost = payload.filling(ResolvedConnectionConfig(host: "mine"))
        #expect(withHost.uri == nil)
        let withoutHost = payload.filling(ResolvedConnectionConfig())
        #expect(withoutHost.uri == "postgres://u:p@h/db")
    }

    @Test func uriKeyIsParsed() {
        let payload = AWSSecretPayload.parse(
            secretString: #"{"uri": "postgres://u:p@h:5432/db"}"#)
        #expect(payload.uri == "postgres://u:p@h:5432/db")
    }
}

@Suite struct AWSSecretRegionTests {
    @Test func regionFromARN() {
        let arn = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:prod/db-AbCdEf"
        #expect(AWSSecretCredentialLoader.region(fromARN: arn) == "eu-central-1")
    }

    @Test func plainSecretNameHasNoARNRegion() {
        #expect(AWSSecretCredentialLoader.region(fromARN: "prod/db") == nil)
    }

    @Test func explicitRegionWins() {
        let config = AWSSecretConfig(
            region: "us-west-2",
            secretID: "arn:aws:secretsmanager:eu-central-1:1:secret:x")
        #expect(AWSSecretCredentialLoader.resolveRegion(config) == "us-west-2")
    }

    @Test func arnRegionUsedWhenNoExplicitRegion() {
        let config = AWSSecretConfig(
            secretID: "arn:aws:secretsmanager:eu-west-1:1:secret:x")
        #expect(AWSSecretCredentialLoader.resolveRegion(config) == "eu-west-1")
    }
}

@Suite struct AWSConfigFileTests {
    private func writeTemp(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aws-test-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func listsProfilesFromConfigAndCredentials() throws {
        let configPath = try writeTemp(
            """
            [default]
            region = eu-central-1

            [profile staging]
            sso_session = my-sso
            region = eu-west-1

            [sso-session my-sso]
            sso_start_url = https://example.awsapps.com/start
            """)
        let credentialsPath = try writeTemp(
            """
            [legacy-keys]
            aws_access_key_id = AKIA...
            aws_secret_access_key = ...
            """)
        defer {
            try? FileManager.default.removeItem(atPath: configPath)
            try? FileManager.default.removeItem(atPath: credentialsPath)
        }
        let names = AWSConfigFile.profileNames(
            configPath: configPath, credentialsPath: credentialsPath)
        #expect(names == ["default", "legacy-keys", "staging"])
    }

    @Test func readsRegionForNamedAndDefaultProfile() throws {
        let configPath = try writeTemp(
            """
            [default]
            region = eu-central-1

            [profile staging]
            region=eu-west-1
            """)
        defer { try? FileManager.default.removeItem(atPath: configPath) }
        #expect(
            AWSConfigFile.region(forProfile: "staging", configPath: configPath)
                == "eu-west-1")
        #expect(
            AWSConfigFile.region(forProfile: nil, configPath: configPath)
                == "eu-central-1")
        #expect(
            AWSConfigFile.region(forProfile: "missing", configPath: configPath) == nil)
    }

    @Test func missingFilesAreHandled() {
        let names = AWSConfigFile.profileNames(
            configPath: "/nonexistent/config", credentialsPath: "/nonexistent/credentials")
        #expect(names.isEmpty)
        #expect(AWSConfigFile.region(forProfile: nil, configPath: "/nonexistent") == nil)
    }
}

@Suite struct AWSSecretProfileCodableTests {
    @Test func profileWithSecretsManagerSourceRoundTrips() throws {
        let profile = ConnectionProfile(
            name: "prod-db",
            driverID: "postgres",
            credentialSource: .awsSecretsManager(
                AWSSecretConfig(
                    profileName: "staging",
                    region: "eu-central-1",
                    secretID: "prod/db"))
        )
        let data = try JSONEncoder().encode([profile])
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: data)
        #expect(decoded == [profile])
        guard case .awsSecretsManager(let config) = decoded[0].credentialSource else {
            Issue.record("expected awsSecretsManager source")
            return
        }
        #expect(config.profileName == "staging")
        #expect(config.region == "eu-central-1")
        #expect(config.secretID == "prod/db")
    }
}

/// Opt-in integration test against real AWS (or LocalStack via
/// DBOSK_AWS_ENDPOINT). Requires DBOSK_AWS_TESTS=1 and DBOSK_AWS_SECRET_ID.
@Suite struct AWSSecretIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBOSK_AWS_TESTS"] == "1"))
    func fetchesRealSecret() async throws {
        let env = ProcessInfo.processInfo.environment
        let secretID = try #require(env["DBOSK_AWS_SECRET_ID"])
        let config = AWSSecretConfig(
            profileName: env["DBOSK_AWS_PROFILE"],
            region: env["DBOSK_AWS_REGION"],
            secretID: secretID,
            endpoint: env["DBOSK_AWS_ENDPOINT"])
        let payload = try await AWSSecretCredentialLoader().load(config)
        #expect(payload.password != nil || payload.uri != nil)
    }
}
