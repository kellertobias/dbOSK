import Foundation
import Testing

@testable import Connections

@Suite struct MCPAccessTests {

    @Test func disabledAllowsNothing() {
        let config = MCPAccessConfig(enabled: false, scope: .allTables)
        #expect(!config.allows(path: ["public", "users"]))
        #expect(!config.allowsReading(path: ["public", "users"]))
    }

    @Test func allTablesAllowsEverything() {
        let config = MCPAccessConfig(enabled: true, scope: .allTables)
        #expect(config.allows(path: ["anything"]))
        #expect(config.allowsReading(path: ["db", "schema", "table"]))
    }

    @Test func allowlistAdmitsEntryAndDescendants() {
        let config = MCPAccessConfig(
            enabled: true, scope: .allowlist([["public"], ["analytics", "events"]]))
        #expect(config.allowsReading(path: ["public"]))
        #expect(config.allowsReading(path: ["public", "users"]))
        #expect(config.allowsReading(path: ["analytics", "events"]))
        #expect(!config.allowsReading(path: ["analytics", "other_table"]))
        #expect(!config.allowsReading(path: ["private", "users"]))
    }

    @Test func parentsAreVisibleButNotReadable() {
        let config = MCPAccessConfig(
            enabled: true, scope: .allowlist([["db", "schema", "users"]]))
        // Visible so clients can walk the tree down to the allowed table…
        #expect(config.allows(path: ["db"]))
        #expect(config.allows(path: ["db", "schema"]))
        // …but a parent is not itself readable.
        #expect(!config.allowsReading(path: ["db"]))
        #expect(!config.allowsReading(path: ["db", "schema"]))
        #expect(config.allowsReading(path: ["db", "schema", "users"]))
        // Siblings are neither visible nor readable.
        #expect(!config.allows(path: ["db", "schema", "orders"]))
    }

    @Test func matchingIsCaseInsensitive() {
        let config = MCPAccessConfig(
            enabled: true, scope: .allowlist([["Public", "Users"]]))
        #expect(config.allowsReading(path: ["public", "users"]))
        #expect(config.allowsReading(path: ["PUBLIC", "USERS"]))
    }

    @Test func storeRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-access-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MCPAccessStore(fileURL: url)
        #expect(store.load().isEmpty)

        let id = UUID()
        let map = [id: MCPAccessConfig(enabled: true, scope: .allowlist([["public"]]))]
        try store.save(map)
        #expect(store.load() == map)
    }
}
