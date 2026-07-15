import Foundation
import Security

/// Stores every connection secret in a single Keychain item, read once per
/// process into memory. Under an ad-hoc/unsigned build (whose code identity
/// changes each build) macOS prompts on the first access to an item created
/// by a different identity; collapsing all secrets into one item means that
/// prompt happens at most once per launch instead of once per credential,
/// and rewriting the item after an allowed read re-owns its ACL so later
/// launches of the same build never prompt at all. Only an *update* to a
/// different build triggers one further prompt — unavoidable without a
/// stable signing identity.
///
/// service = "dev.dbosk.connection", account = a single vault entry holding a
/// JSON `[profileUUID: secret]` map. Items written by pre-vault builds (one
/// per profile UUID) are migrated in and deleted on first load.
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

    /// Loads the vault into the process-wide cache so the (at most one)
    /// Keychain prompt happens at app open instead of on the first connect.
    public func preload() {
        KeychainVault.shared.preload()
    }

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

    func preload() {
        lock.lock()
        defer { lock.unlock() }
        _ = try? loaded()
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
        var map: [String: String]
        var vaultReadable = false
        switch status {
        case errSecSuccess:
            vaultReadable = true
            if let data = result as? Data,
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                map = decoded
            } else {
                map = [:]
            }
        case errSecItemNotFound:
            vaultReadable = true
            map = [:]
        case errSecAuthFailed:
            // The item exists but the user denied this build's prompt. Treat
            // it as empty so callers can re-enter credentials, but leave the
            // item alone: its secrets may still be readable on a future
            // launch when the user allows the prompt.
            map = [:]
        default:
            throw KeychainStore.KeychainError.unexpectedStatus(status)
        }

        let migrated = migrateLegacyItems(into: &map)
        cache = map

        // Rewrite the item so its ACL trusts this build's code identity. An
        // ad-hoc-signed build reading an item created by a different build
        // prompts once per launch; re-owning after an allowed read (or a
        // migration) makes every later launch of the same build silent.
        if migrated || (vaultReadable && !map.isEmpty) {
            try? persist(map)
        }
        return map
    }

    /// One-time import of items written by pre-vault builds, which stored one
    /// generic-password item per profile (account = profile UUID) under the
    /// same service. Listing attributes is not ACL-gated; reading each item's
    /// secret may prompt one final time, after which the item is deleted.
    /// Items whose read is denied stay in place and are retried next launch.
    private func migrateLegacyItems(into map: inout [String: String]) -> Bool {
        let list: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var found: CFTypeRef?
        guard SecItemCopyMatching(list as CFDictionary, &found) == errSecSuccess,
              let items = found as? [[String: Any]] else { return false }

        var migrated = false
        for attributes in items {
            // Legacy accounts are profile UUIDs; this also skips the vault
            // item itself, whose account is not a UUID.
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  UUID(uuidString: account) != nil else { continue }
            let read: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainStore.service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else { continue }
            // The vault wins on conflict: it is newer than any legacy item.
            if map[account] == nil { map[account] = password }
            let delete: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainStore.service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(delete as CFDictionary)
            migrated = true
        }
        return migrated
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
