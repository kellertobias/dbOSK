import DBCore
import Foundation
import SotoSecretsManager

/// Where an AWS Secrets Manager–backed connection gets its credentials from.
/// Authentication uses the standard `~/.aws` config: a named profile (SSO or
/// static keys, including role chains) or the default provider chain.
/// Optional per-field override of which JSON key in the secret holds each
/// connection field. nil fields use the default aliases (host/hostname,
/// username/user, dbname/database, …).
public struct AWSSecretKeyMapping: Codable, Sendable, Hashable {
    public var host: String?
    public var port: String?
    public var user: String?
    public var password: String?
    public var database: String?

    public init(
        host: String? = nil,
        port: String? = nil,
        user: String? = nil,
        password: String? = nil,
        database: String? = nil
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
    }

    public var isEmpty: Bool {
        host == nil && port == nil && user == nil && password == nil && database == nil
    }
}

public struct AWSSecretConfig: Codable, Sendable, Hashable {
    /// Named profile from `~/.aws/config` / `~/.aws/credentials`.
    /// nil uses the default AWS credential chain.
    public var profileName: String?
    /// Explicit region. When nil the region is taken from the secret's ARN,
    /// the profile's config, or the `AWS_REGION` environment variable.
    public var region: String?
    /// Secret name or full ARN.
    public var secretID: String
    /// Custom key names in the secret's JSON; nil uses the default aliases.
    public var keyMapping: AWSSecretKeyMapping?
    /// Custom endpoint (LocalStack); not exposed in the UI.
    public var endpoint: String?

    public init(
        profileName: String? = nil,
        region: String? = nil,
        secretID: String,
        keyMapping: AWSSecretKeyMapping? = nil,
        endpoint: String? = nil
    ) {
        self.profileName = profileName
        self.region = region
        self.secretID = secretID
        self.keyMapping = keyMapping
        self.endpoint = endpoint
    }
}

/// Fields extracted from a secret's payload. Follows the RDS-managed secret
/// shape (`username`/`password`/`host`/`port`/`dbname`) with common aliases;
/// a non-JSON secret string is treated as a bare password.
public struct AWSSecretPayload: Sendable, Equatable {
    public var host: String?
    public var port: Int?
    public var user: String?
    public var password: String?
    public var database: String?
    public var uri: String?
    /// Top-level key names found in the secret's JSON (never values), or nil
    /// for a plain-string secret. Surfaced in connection errors so a
    /// mismatched secret shape is debuggable without exposing its contents.
    public var presentKeys: [String]?

    public init(
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        password: String? = nil,
        database: String? = nil,
        uri: String? = nil,
        presentKeys: [String]? = nil
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.uri = uri
        self.presentKeys = presentKeys
    }

    public var diagnosticsSummary: String {
        if let presentKeys {
            return "AWS secret contained keys: \(presentKeys.joined(separator: ", ")) (values not shown)."
        }
        return "AWS secret was a plain (non-JSON) string; it was used as the password."
    }

    /// Fills only the fields the profile left empty: explicit profile values
    /// (host, port, user, database) win over the secret's, so a secret whose
    /// endpoint is only resolvable inside the VPC can be overridden with a
    /// reachable host. The password always comes from the secret; `uri` is
    /// used only when the profile sets no host of its own.
    public func filling(_ config: ResolvedConnectionConfig) -> ResolvedConnectionConfig {
        var config = config
        let profileHasHost = config.host != nil
        if config.host == nil, let host { config.host = host }
        if config.port == nil, let port { config.port = port }
        if config.user == nil, let user { config.user = user }
        if config.database == nil, let database { config.database = database }
        if let password { config.password = password }
        if !profileHasHost, let uri { config.uri = uri }
        config.credentialDiagnostics = diagnosticsSummary
        return config
    }

    public static func parse(
        secretString: String, mapping: AWSSecretKeyMapping? = nil
    ) -> AWSSecretPayload {
        guard let data = secretString.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return AWSSecretPayload(password: secretString)
        }
        // An explicit mapping key wins outright; only unmapped fields fall
        // back to the alias list.
        func string(_ override: String?, _ aliases: [String]) -> String? {
            for key in override.map({ [$0] }) ?? aliases {
                if let value = object[key] as? String, !value.isEmpty { return value }
                if override != nil, let value = object[key] as? NSNumber {
                    return value.stringValue
                }
            }
            return nil
        }
        func int(_ override: String?, _ aliases: [String]) -> Int? {
            for key in override.map({ [$0] }) ?? aliases {
                if let value = object[key] as? Int { return value }
                if let text = object[key] as? String, let value = Int(text) { return value }
            }
            return nil
        }
        return AWSSecretPayload(
            host: string(mapping?.host, ["host", "hostname"]),
            port: int(mapping?.port, ["port"]),
            user: string(mapping?.user, ["username", "user"]),
            password: string(mapping?.password, ["password"]),
            database: string(mapping?.database, ["dbname", "database"]),
            uri: string(nil, ["uri", "url"]),
            presentKeys: object.keys.sorted()
        )
    }
}

public enum AWSSecretCredentialError: Error, CustomStringConvertible {
    case missingRegion(secretID: String)
    case emptySecret(secretID: String)
    case fetchFailed(secretID: String, profile: String?, underlying: String)

    public var description: String {
        switch self {
        case .missingRegion(let secretID):
            return """
                No AWS region for secret "\(secretID)". Set a region on the \
                connection, use a full secret ARN, or add one to the profile \
                in ~/.aws/config.
                """
        case .emptySecret(let secretID):
            return "Secret \"\(secretID)\" has no string value."
        case .fetchFailed(let secretID, let profile, let underlying):
            var message = "Could not read secret \"\(secretID)\" from AWS Secrets Manager."
            let lowered = underlying.lowercased()
            if lowered.contains("sso") || lowered.contains("token")
                || lowered.contains("expired") || lowered.contains("credential")
            {
                let loginHint = profile.map { "aws sso login --profile \($0)" }
                    ?? "aws sso login"
                message += " Your AWS session may be missing or expired — try: \(loginHint)"
            }
            return "\(message)\n\(underlying)"
        }
    }
}

/// Minimal reader for `~/.aws/config` and `~/.aws/credentials`: profile names
/// for the UI picker and per-profile regions. Credential *resolution* (SSO
/// token cache, role chains, static keys) is soto-core's job, not ours.
public enum AWSConfigFile {
    public static var defaultConfigPath: String {
        ("~/.aws/config" as NSString).expandingTildeInPath
    }
    public static var defaultCredentialsPath: String {
        ("~/.aws/credentials" as NSString).expandingTildeInPath
    }

    public static func profileNames(
        configPath: String = defaultConfigPath,
        credentialsPath: String = defaultCredentialsPath
    ) -> [String] {
        var names = Set<String>()
        for (path, sectionPrefix) in [(configPath, "profile "), (credentialsPath, "")] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            for name in sectionNames(in: text) {
                if name == "default" {
                    names.insert(name)
                } else if sectionPrefix.isEmpty {
                    names.insert(name)
                } else if name.hasPrefix(sectionPrefix) {
                    names.insert(
                        String(name.dropFirst(sectionPrefix.count))
                            .trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return names.sorted()
    }

    public static func region(
        forProfile profile: String?,
        configPath: String = defaultConfigPath
    ) -> String? {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }
        let wanted = profile ?? "default"
        var inSection = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                let section = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                inSection = section == wanted || section == "profile \(wanted)"
                continue
            }
            guard inSection else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces) == "region"
            {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func sectionNames(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
            return String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Fetches a secret from AWS Secrets Manager at connect time. Credentials come
/// from soto-core's config-file provider, which resolves SSO profiles (cached
/// tokens from `aws sso login`), assume-role chains, and static keys.
public struct AWSSecretCredentialLoader: Sendable {
    public init() {}

    public func load(_ config: AWSSecretConfig) async throws -> AWSSecretPayload {
        let secretString = try await fetchSecretString(config)
        return AWSSecretPayload.parse(
            secretString: secretString, mapping: config.keyMapping)
    }

    /// Fetches the secret and returns only its top-level JSON key names,
    /// sorted (empty for a plain-string secret). Backs the key-mapping
    /// dropdowns in the connection editor.
    public func availableKeys(_ config: AWSSecretConfig) async throws -> [String] {
        let secretString = try await fetchSecretString(config)
        guard let data = secretString.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        return object.keys.sorted()
    }

    private func fetchSecretString(_ config: AWSSecretConfig) async throws -> String {
        guard let region = Self.resolveRegion(config) else {
            throw AWSSecretCredentialError.missingRegion(secretID: config.secretID)
        }

        // `.configFile` covers static keys and assume-role chains but not a
        // profile that is *directly* an SSO permission set (sso_session /
        // sso_account_id keys, no role_arn) — that needs `.sso`. The selector
        // tries each in turn, mirroring soto's `.default` chain.
        let credentialProvider: CredentialProviderFactory =
            config.profileName.map {
                .selector(.configFile(profile: $0), .sso(profileName: $0))
            } ?? .default
        let client = AWSClient(credentialProvider: credentialProvider)
        let secretsManager = SecretsManager(
            client: client, region: Region(rawValue: region), endpoint: config.endpoint)

        let secretString: String?
        do {
            let output = try await secretsManager.getSecretValue(
                SecretsManager.GetSecretValueRequest(secretId: config.secretID))
            secretString = output.secretString
        } catch {
            try? await client.shutdown()
            throw AWSSecretCredentialError.fetchFailed(
                secretID: config.secretID,
                profile: config.profileName,
                underlying: String(reflecting: error))
        }
        try? await client.shutdown()

        guard let secretString, !secretString.isEmpty else {
            throw AWSSecretCredentialError.emptySecret(secretID: config.secretID)
        }
        return secretString
    }

    /// Explicit region → secret ARN → profile config → environment.
    public static func resolveRegion(_ config: AWSSecretConfig) -> String? {
        if let region = config.region, !region.isEmpty { return region }
        if let region = region(fromARN: config.secretID) { return region }
        if let region = AWSConfigFile.region(forProfile: config.profileName) {
            return region
        }
        let env = ProcessInfo.processInfo.environment
        return env["AWS_REGION"] ?? env["AWS_DEFAULT_REGION"]
    }

    /// arn:aws:secretsmanager:REGION:account:secret:name → REGION
    public static func region(fromARN arn: String) -> String? {
        guard arn.hasPrefix("arn:") else { return nil }
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 3, !parts[3].isEmpty else { return nil }
        return String(parts[3])
    }
}
