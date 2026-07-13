import DBCore
import Foundation

/// A user-saved query for a connection.
public struct SavedQuery: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var text: String

    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// User annotations for one table/collection.
public struct TableMeta: Codable, Sendable, Hashable {
    public var note: String?
    /// User-defined sidebar group within the table's schema/database.
    public var group: String?
    public var hidden: Bool

    public init(note: String? = nil, group: String? = nil, hidden: Bool = false) {
        self.note = note
        self.group = group
        self.hidden = hidden
    }

    /// True when nothing is set — the entry can be pruned from storage.
    public var isEmpty: Bool {
        note == nil && group == nil && !hidden
    }
}

/// One executed query, recorded automatically.
public struct QueryHistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var executedAt: Date
    public var succeeded: Bool

    public init(id: UUID = UUID(), text: String, executedAt: Date, succeeded: Bool) {
        self.id = id
        self.text = text
        self.executedAt = executedAt
        self.succeeded = succeeded
    }
}

/// Per-connection user metadata: saved queries, query history, and table
/// annotations. Stored as a sidecar JSON per profile, never in the
/// connection itself.
public struct ConnectionMetadata: Codable, Sendable, Equatable {
    /// Most queries the history keeps per connection.
    public static let historyLimit = 100

    public var savedQueries: [SavedQuery]
    /// Newest first, capped at `historyLimit`.
    public var history: [QueryHistoryEntry]
    /// Keyed by `Self.key(for:)` of the table's namespace path.
    public var tables: [String: TableMeta]

    public init(
        savedQueries: [SavedQuery] = [],
        history: [QueryHistoryEntry] = [],
        tables: [String: TableMeta] = [:]
    ) {
        self.savedQueries = savedQueries
        self.history = history
        self.tables = tables
    }

    // Custom decoding: `history` is absent in pre-history metadata files.
    private enum CodingKeys: String, CodingKey {
        case savedQueries, history, tables
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedQueries = try c.decodeIfPresent([SavedQuery].self, forKey: .savedQueries) ?? []
        history = try c.decodeIfPresent([QueryHistoryEntry].self, forKey: .history) ?? []
        tables = try c.decodeIfPresent([String: TableMeta].self, forKey: .tables) ?? [:]
    }

    /// Prepends an executed query. Re-running the newest entry updates it
    /// in place instead of stacking duplicates; the list stays capped.
    public mutating func recordHistory(text: String, succeeded: Bool, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let newest = history.first, newest.text == trimmed {
            history[0].executedAt = date
            history[0].succeeded = succeeded
            return
        }
        history.insert(
            QueryHistoryEntry(text: trimmed, executedAt: date, succeeded: succeeded),
            at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    public static func key(for path: [String]) -> String {
        path.joined(separator: "\u{1F}")
    }

    // MARK: Table accessors (prune empty entries on write)

    public func meta(for path: [String]) -> TableMeta {
        tables[Self.key(for: path)] ?? TableMeta()
    }

    public mutating func update(_ path: [String], _ mutate: (inout TableMeta) -> Void) {
        var meta = meta(for: path)
        mutate(&meta)
        let key = Self.key(for: path)
        if meta.isEmpty {
            tables.removeValue(forKey: key)
        } else {
            tables[key] = meta
        }
    }

    /// All group names in use under tables (sorted, unique).
    public var groupNames: [String] {
        Array(Set(tables.values.compactMap(\.group))).sorted()
    }

    // MARK: Subtree visibility
    //
    // Hidden schemas/databases are one entry at their own path — never a
    // flag per descendant table — so these scans touch only stored
    // annotations, not every table in the database.

    /// True when any stored entry strictly below `path` is hidden.
    public func hasHiddenDescendants(of path: [String]) -> Bool {
        let prefix = Self.key(for: path) + "\u{1F}"
        return tables.contains { $0.key.hasPrefix(prefix) && $0.value.hidden }
    }

    /// Clears the hidden flag on every stored entry strictly below `path`,
    /// pruning entries that become empty.
    public mutating func unhideDescendants(of path: [String]) {
        let prefix = Self.key(for: path) + "\u{1F}"
        for key in Array(tables.keys) where key.hasPrefix(prefix) {
            clearHidden(at: key)
        }
    }

    /// Clears every hidden flag on the connection (tables and schemas).
    public mutating func unhideAll() {
        for key in Array(tables.keys) {
            clearHidden(at: key)
        }
    }

    private mutating func clearHidden(at key: String) {
        guard var meta = tables[key], meta.hidden else { return }
        meta.hidden = false
        tables[key] = meta.isEmpty ? nil : meta
    }
}

/// Loads/saves per-profile metadata JSON files.
public struct MetadataStore: Sendable {
    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("dbosk/metadata")
        }
    }

    private func fileURL(for profileID: UUID) -> URL {
        directory.appendingPathComponent("\(profileID.uuidString).json")
    }

    public func load(for profileID: UUID) -> ConnectionMetadata {
        let url = fileURL(for: profileID)
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(ConnectionMetadata.self, from: data)
        else { return ConnectionMetadata() }
        return metadata
    }

    public func save(_ metadata: ConnectionMetadata, for profileID: UUID) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: fileURL(for: profileID), options: .atomic)
    }

    public func delete(for profileID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: profileID))
    }
}
