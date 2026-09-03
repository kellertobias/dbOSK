import DBCore
import Foundation
import Testing

@testable import Connections

@Suite struct AuthenticationDatabaseTests {
    private func makeScript(_ json: String) throws -> ScriptConfig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-authdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cred.sh")
        try "#!/bin/sh\necho '\(json)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return ScriptConfig(path: url.path)
    }

    @Test func profileRoundTripsAuthenticationDatabase() throws {
        let profile = ConnectionProfile(
            name: "mongo", driverID: "mongodb", host: "localhost", user: "app",
            database: "orders", authenticationDatabase: "admin",
            credentialSource: .keychain)
        let data = try JSONEncoder().encode([profile])
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: data)
        #expect(decoded == [profile])
        #expect(decoded[0].authenticationDatabase == "admin")
    }

    @Test func profileWithoutAuthenticationDatabaseStillDecodes() throws {
        // A profile saved before the field existed has no key for it.
        let json = """
            {"id": "\(UUID().uuidString)", "name": "old", "driverID": "mongodb",
             "host": "h", "database": "orders", "tls": "preferred",
             "credentialSource": {"keychain": {}}}
            """
        let decoded = try JSONDecoder().decode(
            ConnectionProfile.self, from: Data(json.utf8))
        #expect(decoded.authenticationDatabase == nil)
        #expect(decoded.database == "orders")
    }

    @Test func resolverPassesProfileValueThrough() async throws {
        let profile = ConnectionProfile(
            name: "mongo", driverID: "mongodb", host: "h", user: "u",
            database: "orders", authenticationDatabase: "users")
        let config = try await CredentialResolver().resolve(profile)
        #expect(config.database == "orders")
        #expect(config.authenticationDatabase == "users")
    }

    @Test func scriptOverridesAuthenticationDatabase() async throws {
        let script = try makeScript(
            #"{"password": "pw", "authenticationDatabase": "from-script"}"#)
        let profile = ConnectionProfile(
            name: "mongo", driverID: "mongodb", host: "h", user: "u",
            database: "orders", authenticationDatabase: "admin",
            credentialSource: .script(script))
        let config = try await CredentialResolver().resolve(profile)
        #expect(config.authenticationDatabase == "from-script")
        #expect(config.database == "orders")
    }

    @Test func scriptAcceptsAuthSourceAlias() throws {
        let creds = try JSONDecoder().decode(
            ScriptCredentials.self, from: Data(#"{"authSource": "admin"}"#.utf8))
        #expect(creds.authenticationDatabase == "admin")

        let explicit = try JSONDecoder().decode(
            ScriptCredentials.self,
            from: Data(#"{"authSource": "alias", "authenticationDatabase": "explicit"}"#.utf8))
        #expect(explicit.authenticationDatabase == "explicit")
    }

    @Test func awsSecretParsesAuthenticationDatabaseAliases() {
        #expect(
            AWSSecretPayload.parse(secretString: #"{"authSource": "admin"}"#)
                .authenticationDatabase == "admin")
        #expect(
            AWSSecretPayload.parse(secretString: #"{"authdb": "users"}"#)
                .authenticationDatabase == "users")
        #expect(
            AWSSecretPayload.parse(
                secretString: #"{"auth": "mapped", "authSource": "alias"}"#,
                mapping: AWSSecretKeyMapping(authenticationDatabase: "auth")
            ).authenticationDatabase == "mapped")
    }

    @Test func awsSecretFillsOnlyWhenProfileLeavesItEmpty() {
        let payload = AWSSecretPayload(password: "pw", authenticationDatabase: "secret-auth")
        #expect(payload.filling(ResolvedConnectionConfig()).authenticationDatabase == "secret-auth")
        let kept = payload.filling(ResolvedConnectionConfig(authenticationDatabase: "mine"))
        #expect(kept.authenticationDatabase == "mine")
    }

    @Test func awsKeyMappingRoundTrips() throws {
        let mapping = AWSSecretKeyMapping(authenticationDatabase: "auth_db")
        #expect(!mapping.isEmpty)
        let profile = ConnectionProfile(
            name: "m", driverID: "mongodb",
            credentialSource: .awsSecretsManager(
                AWSSecretConfig(secretID: "s", keyMapping: mapping)))
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        #expect(decoded == profile)
    }
}
