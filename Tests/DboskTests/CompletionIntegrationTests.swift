import Connections
import DBCore
import DBDriverSQLite
import Foundation
import GRDB
import QueryEditor
import Testing

@testable import Dbosk

/// End-to-end typeahead pipeline against a live SQLite schema: session
/// namespace/column caches → SchemaCompletionProvider snapshot →
/// CompletionEngine candidates, including the async column round-trip.
@Suite @MainActor struct CompletionIntegrationTests {
    private func makeSession() async throws -> ConnectionSession {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbosk-completion-\(UUID().uuidString).sqlite")
            .path
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);
                CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL);
                """)
        }
        let driver = try SQLiteDriver(config: ResolvedConnectionConfig(filePath: path))
        try await driver.connect()
        let profile = ConnectionProfile(
            name: "completion-test", driverID: "sqlite", filePath: path)
        let session = ConnectionSession(profile: profile, driver: driver)
        await session.loadRoot()
        for root in session.rootNamespaces where root.isExpandable {
            await session.loadChildren(of: root)
        }
        return session
    }

    private func complete(
        _ marked: String, session: ConnectionSession, snapshot: SchemaSnapshot
    ) -> CompletionResult? {
        let cursor = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        return CompletionEngine(identifierQuote: session.descriptor.identifierQuote)
            .complete(text: text, cursorUTF16: cursor, schema: snapshot, explicit: false)
    }

    @Test func tableNamesCompleteFromLiveSchema() async throws {
        let session = try await makeSession()
        let snapshot = session.completionProvider.snapshot(onUpdate: {})

        let result = complete("SELECT * FROM us|", session: session, snapshot: snapshot)
        #expect(result?.items.first?.label == "users")
        #expect(result?.items.first?.kind == .table)
    }

    @Test func columnsArriveViaAsyncRoundTrip() async throws {
        let session = try await makeSession()
        let provider = session.completionProvider

        // First pass: columns not cached yet — the engine reports the gap.
        let cold = try #require(complete(
            "SELECT u.| FROM users u", session: session,
            snapshot: provider.snapshot(onUpdate: {})))
        #expect(cold.items.isEmpty)
        #expect(cold.missingColumnTables.count == 1)

        // Fetch what was missing, as the editor controller would.
        await withCheckedContinuation { continuation in
            provider.requestColumns(for: cold.missingColumnTables) {
                continuation.resume()
            }
        }

        // Second pass: alias resolves to the freshly cached columns.
        let warm = complete(
            "SELECT u.| FROM users u", session: session,
            snapshot: provider.snapshot(onUpdate: {}))
        #expect(warm?.items.map(\.label) == ["email", "id", "name"])
        #expect(warm?.items.allSatisfy { $0.kind == .column } == true)
        #expect(warm?.missingColumnTables.isEmpty == true)
    }
}
