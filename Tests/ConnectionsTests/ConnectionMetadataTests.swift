import Foundation
import Testing

@testable import Connections

@Suite struct ConnectionMetadataTests {
    @Test func storeRoundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-meta-\(UUID().uuidString)")
        let store = MetadataStore(directory: dir)
        let profileID = UUID()

        // Missing file loads as empty metadata.
        #expect(store.load(for: profileID) == ConnectionMetadata())

        var metadata = ConnectionMetadata()
        metadata.savedQueries = [
            SavedQuery(name: "active users", text: "SELECT * FROM users WHERE active")
        ]
        metadata.update(["public", "users"]) {
            $0.note = "Main user table"
            $0.group = "Core"
        }
        metadata.update(["public", "audit_log"]) { $0.hidden = true }

        try store.save(metadata, for: profileID)
        let loaded = store.load(for: profileID)
        #expect(loaded == metadata)
        #expect(loaded.meta(for: ["public", "users"]).note == "Main user table")
        #expect(loaded.meta(for: ["public", "audit_log"]).hidden)
        #expect(loaded.groupNames == ["Core"])

        store.delete(for: profileID)
        #expect(store.load(for: profileID) == ConnectionMetadata())
    }

    @Test func emptyEntriesArePruned() {
        var metadata = ConnectionMetadata()
        metadata.update(["public", "users"]) { $0.note = "x" }
        #expect(metadata.tables.count == 1)
        metadata.update(["public", "users"]) { $0.note = nil }
        #expect(metadata.tables.isEmpty)

        metadata.update(["a", "b"]) { $0.hidden = true }
        metadata.update(["a", "b"]) { $0.hidden = false }
        #expect(metadata.tables.isEmpty)
    }

    @Test func historyRecordsDedupsAndCaps() {
        var metadata = ConnectionMetadata()

        metadata.recordHistory(text: "SELECT 1", succeeded: true)
        metadata.recordHistory(text: "SELECT 2", succeeded: true)
        #expect(metadata.history.map(\.text) == ["SELECT 2", "SELECT 1"])

        // Re-running the newest entry updates it in place.
        metadata.recordHistory(text: "  SELECT 2  ", succeeded: false)
        #expect(metadata.history.count == 2)
        #expect(metadata.history[0].succeeded == false)

        // Blank queries are ignored.
        metadata.recordHistory(text: "   \n", succeeded: true)
        #expect(metadata.history.count == 2)

        // The list stays capped at the limit, newest first.
        for index in 0..<(ConnectionMetadata.historyLimit + 20) {
            metadata.recordHistory(text: "SELECT \(index + 10)", succeeded: true)
        }
        #expect(metadata.history.count == ConnectionMetadata.historyLimit)
        #expect(metadata.history.first?.text
            == "SELECT \(ConnectionMetadata.historyLimit + 29)")
    }

    @Test func decodesPreHistoryMetadata() throws {
        // Files written before the history field must load cleanly.
        let legacy = #"{"savedQueries": [], "tables": {}}"#
        let metadata = try JSONDecoder().decode(
            ConnectionMetadata.self, from: Data(legacy.utf8))
        #expect(metadata.history.isEmpty)
    }

    @Test func historyRoundtripsThroughStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-history-\(UUID().uuidString)")
        let store = MetadataStore(directory: dir)
        let profileID = UUID()

        var metadata = ConnectionMetadata()
        metadata.recordHistory(text: "SELECT * FROM users", succeeded: true)
        try store.save(metadata, for: profileID)

        let loaded = store.load(for: profileID)
        #expect(loaded.history.count == 1)
        #expect(loaded.history[0].text == "SELECT * FROM users")
        #expect(loaded.history[0].succeeded)
    }

    @Test func pathKeysDoNotCollide() {
        // ["a.b", "c"] and ["a", "b.c"] must map to different keys.
        #expect(ConnectionMetadata.key(for: ["a.b", "c"])
            != ConnectionMetadata.key(for: ["a", "b.c"]))
    }
}
