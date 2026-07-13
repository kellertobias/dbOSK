import DBCore
import Foundation

/// Turns a saved `ConnectionProfile` into a `ResolvedConnectionConfig` with
/// secrets filled in from the Keychain or the credential script.
public struct CredentialResolver: Sendable {
    private let keychain: KeychainStore
    private let scriptLoader: ScriptCredentialLoader
    private let awsSecretLoader: AWSSecretCredentialLoader

    public init(
        keychain: KeychainStore = KeychainStore(),
        scriptLoader: ScriptCredentialLoader = ScriptCredentialLoader(),
        awsSecretLoader: AWSSecretCredentialLoader = AWSSecretCredentialLoader()
    ) {
        self.keychain = keychain
        self.scriptLoader = scriptLoader
        self.awsSecretLoader = awsSecretLoader
    }

    public func resolve(_ profile: ConnectionProfile) async throws -> ResolvedConnectionConfig {
        var config = ResolvedConnectionConfig(
            host: profile.host,
            port: profile.port,
            user: profile.user,
            database: profile.database,
            filePath: profile.filePath,
            tls: profile.tls
        )

        switch profile.credentialSource {
        case .none:
            break
        case .keychain:
            config.password = try keychain.password(for: profile.id)
        case .script(let scriptConfig):
            let credentials = try await scriptLoader.load(scriptConfig)
            if let host = credentials.host { config.host = host }
            if let port = credentials.port { config.port = port }
            if let user = credentials.user { config.user = user }
            if let password = credentials.password { config.password = password }
            if let database = credentials.database { config.database = database }
            config.uri = credentials.uri
        case .awsSecretsManager(let awsConfig):
            let payload = try await awsSecretLoader.load(awsConfig)
            config = payload.filling(config)
        }
        return config
    }
}

// MARK: - Profile persistence (no secrets)

public struct ProfileStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("dbosk/connections.json")
        }
    }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }
}
