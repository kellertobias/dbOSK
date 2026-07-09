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

    @Test func pathKeysDoNotCollide() {
        // ["a.b", "c"] and ["a", "b.c"] must map to different keys.
        #expect(ConnectionMetadata.key(for: ["a.b", "c"])
            != ConnectionMetadata.key(for: ["a", "b.c"]))
    }
}
