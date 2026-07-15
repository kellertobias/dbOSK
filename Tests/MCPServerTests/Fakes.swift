import Connections
import DBCore
import Foundation

@testable import MCPServer

/// SQL driver stub: emits canned rows, optionally after a delay (for timeout
/// tests). Cancellation-aware like real drivers.
struct FakeDriver: DatabaseDriver {
    static let descriptor = DriverDescriptor(
        id: "fake",
        displayName: "Fake",
        queryLanguage: .sql,
        defaultPort: nil,
        supportsStreaming: true,
        supportsServerSideCancel: false,
        sqlDialect: .postgres)

    let rows: [[DBValue]]
    let delay: Duration?

    init(config: ResolvedConnectionConfig) throws {
        self.rows = []
        self.delay = nil
    }

    init(rows: [[DBValue]], delay: Duration? = nil) {
        self.rows = rows
        self.delay = delay
    }

    func connect() async throws {}
    func disconnect() async {}

    func listNamespaces(parent: Namespace?) async throws -> [Namespace] {
        if parent == nil {
            return [
                Namespace(path: ["public"], kind: .schema, isExpandable: true),
                Namespace(path: ["private"], kind: .schema, isExpandable: true),
            ]
        }
        return [
            Namespace(
                path: parent!.path + ["users"], kind: .table(.table), isExpandable: false),
            Namespace(
                path: parent!.path + ["orders"], kind: .table(.table), isExpandable: false),
        ]
    }

    func listColumns(of table: Namespace) async throws -> [ColumnMeta] {
        [ColumnMeta(name: "id", dbTypeName: "int")]
    }

    func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        let rows = self.rows
        let delay = self.delay
        let stream = AsyncThrowingStream<QueryResultChunk, Error> { continuation in
            let task = Task {
                if let delay {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                let resultRows = rows.enumerated().map {
                    ResultRow(id: $0.offset, values: $0.element)
                }
                continuation.yield(QueryResultChunk(rows: resultRows, isFinal: true))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return QueryExecution(
            columns: [ColumnMeta(name: "value", dbTypeName: "text")],
            chunks: stream,
            cancel: {})
    }

    func explain(_ query: DriverQuery, analyze: Bool) async throws -> ExplainPlan {
        throw DBError(kind: .unsupported, message: "Fake driver has no explain")
    }

    func setActiveNamespace(_ name: String?) async throws {
        throw DBError(kind: .unsupported, message: "unsupported")
    }
}

struct StubProvider: MCPConnectionProvider {
    let items: [ExposedConnection]
    func connections() async -> [ExposedConnection] { items }
}

func exposed(
    id: String = "11111111-1111-1111-1111-111111111111",
    name: String = "test-db",
    access: MCPAccessConfig = MCPAccessConfig(enabled: true, scope: .allTables),
    driver: FakeDriver = FakeDriver(rows: [[.int(1)], [.int(2)]])
) -> ExposedConnection {
    ExposedConnection(
        id: id,
        name: name,
        engine: "Fake",
        queryLanguage: .sql,
        sqlDialect: .postgres,
        explainSupport: .none,
        access: access,
        driver: { driver })
}
