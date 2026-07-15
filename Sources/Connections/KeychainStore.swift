import Foundation
import Security

/// Stores every connection secret in a single Keychain item, read once per
/// process into memory. Under an ad-hoc/unsigned build (whose code identity
/// changes each build) macOS prompts for the login password on the first
/// access to an item created by a different identity; collapsing all secrets
/// into one item means that prompt happens at most once per launch instead of
/// once per credential.
///
/// service = "dev.dbosk.connection", account = a single vault entry holding a
/// JSON `[profileUUID: secret]` map.
public struct KeychainStore: Sendable {
    public static let service = "dev.dbosk.connection"
    /// Account name of the one item that holds every secret.
    static let vaultAccount = "__all_credentials__"

    public enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        public var description: String {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    public init() {}

    public func setPassword(_ password: String, for profileID: UUID) throws {
        try KeychainVault.shared.set(password, for: profileID.uuidString)
    }

    public func password(for profileID: UUID) throws -> String? {
        try KeychainVault.shared.get(profileID.uuidString)
    }

    public func deletePassword(for profileID: UUID) throws {
        try KeychainVault.shared.remove(profileID.uuidString)
    }

    // MARK: MCP server bearer token

    private static let mcpTokenKey = "mcp-server-token"

    public func mcpToken() throws -> String? {
        try KeychainVault.shared.get(Self.mcpTokenKey)
    }

    public func setMCPToken(_ token: String) throws {
        try KeychainVault.shared.set(token, for: Self.mcpTokenKey)
    }
}

/// Process-wide, thread-safe cache of the one credentials item. Loaded lazily
/// on first access (a single Keychain read → a single OS prompt) and served
/// from memory thereafter; writes rewrite the item via delete-then-add, which
/// is not ACL-gated and so does not prompt.
private final class KeychainVault: @unchecked Sendable {
    static let shared = KeychainVault()

    private let lock = NSLock()
    /// nil until the first Keychain read; `[:]` once loaded and found empty.
    private var cache: [String: String]?

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: KeychainStore.vaultAccount,
        ]
    }

    func get(_ key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try loaded()[key]
    }

    func set(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var map = try loaded()
        map[key] = value
        try persist(map)
    }

    func remove(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var map = try loaded()
        guard map.removeValue(forKey: key) != nil else { return }
        try persist(map)
    }

    /// Returns the cached map, reading the single Keychain item on first use.
    private func loaded() throws -> [String: String] {
        if let cache { return cache }

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let map: [String: String]
        switch status {
        case errSecSuccess:
            if let data = result as? Data,
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                map = decoded
            } else {
                map = [:]
            }
        case errSecItemNotFound:
            map = [:]
        case errSecAuthFailed:
            // The item exists but this build's signature can't unlock it (a
            // stale item from a different-identity build). Treat it as empty
            // so callers re-authenticate; the next write replaces it cleanly.
            map = [:]
        default:
            throw KeychainStore.KeychainError.unexpectedStatus(status)
        }
        cache = map
        return map
    }

    /// Rewrites the single item. Delete-then-add rather than update: an item
    /// left by a build with a different code signature has an ACL that rejects
    /// SecItemUpdate with errSecAuthFailed. Deleting by attribute match is not
    /// ACL-gated, and the fresh add re-establishes the item under the current
    /// identity, so writes never prompt.
    private func persist(_ map: [String: String]) throws {
        cache = map
        let data = try JSONEncoder().encode(map)
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStore.KeychainError.unexpectedStatus(status)
        }
    }
}
