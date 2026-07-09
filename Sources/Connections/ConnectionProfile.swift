import DBCore
import Foundation

public struct ScriptConfig: Codable, Sendable, Hashable {
    public var path: String
    public var args: [String]
    public var timeoutSeconds: Double

    public init(path: String, args: [String] = [], timeoutSeconds: Double = 30) {
        self.path = path
        self.args = args
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum CredentialSource: Codable, Sendable, Hashable {
    /// Password stored in the macOS Keychain under the profile's UUID.
    case keychain
    /// Credentials resolved at connect time by running a user script that
    /// prints JSON to stdout.
    case script(ScriptConfig)
    case none
}

/// A color from the fixed palette used by `ConnectionLabel`. Rendering is up
/// to the UI layer; the model only stores the semantic tag.
public enum ColorTag: String, Codable, Sendable, Hashable, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray
}

/// A saved connection. Never contains secrets — those live in the Keychain
/// or are resolved by the script at connect time.
public struct ConnectionProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Optional group for organizing the connection list (e.g. "Production").
    public var groupName: String?
    /// References a `ConnectionLabel` defined in Preferences, or nil for none.
    public var labelID: UUID?
    /// Matches `DriverDescriptor.id`, e.g. "postgres", "mysql", "mongodb", "sqlite".
    public var driverID: String
    public var host: String?
    public var port: Int?
    public var user: String?
    public var database: String?
    public var filePath: String?
    public var tls: ResolvedConnectionConfig.TLSMode
    public var credentialSource: CredentialSource

    /// Set only when decoding a pre-labels profile that stored a fixed
    /// `colorTag`. `AppModel` migrates these into named labels on load and then
    /// clears the field; it is never encoded back out.
    public var legacyColorTag: ColorTag?

    public init(
        id: UUID = UUID(),
        name: String,
        groupName: String? = nil,
        labelID: UUID? = nil,
        driverID: String,
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        database: String? = nil,
        filePath: String? = nil,
        tls: ResolvedConnectionConfig.TLSMode = .preferred,
        credentialSource: CredentialSource = .none
    ) {
        self.id = id
        self.name = name
        self.groupName = groupName
        self.labelID = labelID
        self.driverID = driverID
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.filePath = filePath
        self.tls = tls
        self.credentialSource = credentialSource
        self.legacyColorTag = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, groupName, labelID, driverID, host, port, user
        case database, filePath, tls, credentialSource
        case colorTag  // legacy: decode-only, migrated into a label on load
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
        labelID = try c.decodeIfPresent(UUID.self, forKey: .labelID)
        driverID = try c.decode(String.self, forKey: .driverID)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        database = try c.decodeIfPresent(String.self, forKey: .database)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        tls = try c.decode(ResolvedConnectionConfig.TLSMode.self, forKey: .tls)
        credentialSource = try c.decode(CredentialSource.self, forKey: .credentialSource)
        legacyColorTag = try c.decodeIfPresent(ColorTag.self, forKey: .colorTag)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(groupName, forKey: .groupName)
        try c.encodeIfPresent(labelID, forKey: .labelID)
        try c.encode(driverID, forKey: .driverID)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(user, forKey: .user)
        try c.encodeIfPresent(database, forKey: .database)
        try c.encodeIfPresent(filePath, forKey: .filePath)
        try c.encode(tls, forKey: .tls)
        try c.encode(credentialSource, forKey: .credentialSource)
        // legacyColorTag is intentionally not encoded.
    }
}

extension ResolvedConnectionConfig.TLSMode {
    public var displayName: String {
        switch self {
        case .disabled: return "Disabled"
        case .preferred: return "Preferred"
        case .required: return "Required"
        }
    }
}
