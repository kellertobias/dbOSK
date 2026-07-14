import DBCore
import Foundation

/// Read-only driver that talks to a Metabase instance over its REST API and
/// exposes every database Metabase itself has access to.
///
/// Config mapping (no dedicated HTTP fields exist on the profile):
/// - `config.host` carries the Metabase base URL, e.g. "https://metabase.example.com"
///   (a bare host is normalized to https).
/// - `config.password` carries the Metabase session token, sent as the
///   `X-Metabase-Session` header. The token is obtained by the app's SSO
///   login flow and stored in the Keychain like any other password.
///
/// A rejected session (HTTP 401) surfaces as `DBError(kind: .authenticationExpired)`
/// so the UI can prompt for a fresh SSO login instead of showing a generic error.
public actor MetabaseDriver: DatabaseDriver {
    public static let descriptor = DriverDescriptor(
        id: "metabase",
        displayName: "Metabase",
        queryLanguage: .sql,
        defaultPort: nil,
        supportsStreaming: false,
        supportsServerSideCancel: false,
        identifierQuote: "\"",
        sqlDialect: nil,
        supportsTableEditing: false,
        supportsDDL: false,
        explainSupport: .none,
        // Selects which Metabase-exposed database native queries run against.
        // Unlike SQL drivers this is driver-local state, not a session statement.
        activeNamespaceKind: .database
    )

    private let config: ResolvedConnectionConfig
    private let client: any MetabaseHTTPClient

    private var databases: [MetabaseDatabaseInfo] = []
    /// Sidebar display name → Metabase database id. Names are usually unique;
    /// duplicates get an " (id)" suffix so every node stays addressable.
    private var databaseIDsByName: [String: Int] = [:]
    private var orderedDatabaseNames: [String] = []
    private var metadataByDatabaseID: [Int: MetabaseDatabaseMetadata] = [:]
    /// Toolbar-selected target for native queries; driver-local, no SQL sent.
    private var activeDatabaseName: String?
    /// In-flight `/api/dataset` request, kept so `QueryExecution.cancel` can
    /// abort the transfer.
    private var activeRequest: Task<(Data, HTTPURLResponse), Error>?

    public init(config: ResolvedConnectionConfig) throws {
        self.config = config
        self.client = URLSessionMetabaseHTTPClient()
    }

    /// Test entry point with an injected transport.
    public init(config: ResolvedConnectionConfig, client: any MetabaseHTTPClient) {
        self.config = config
        self.client = client
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        activeDatabaseName = nil
        let request = try makeRequest(path: "/api/user/current")
        _ = try await send(request, failureKind: .connectionFailed)
        try await loadDatabases()
    }

    public func disconnect() async {
        activeRequest?.cancel()
        activeRequest = nil
        databases = []
        databaseIDsByName = [:]
        orderedDatabaseNames = []
        metadataByDatabaseID = [:]
        activeDatabaseName = nil
    }

    // MARK: - Namespaces

    public func listNamespaces(parent: Namespace?) async throws -> [Namespace] {
        guard let parent else {
            if databases.isEmpty { try await loadDatabases() }
            return orderedDatabaseNames.map {
                Namespace(path: [$0], kind: .database, isExpandable: true)
            }
        }

        switch parent.kind {
        case .database:
            let databaseName = parent.path[0]
            let tables = try await tables(inDatabaseNamed: databaseName)
            let schemas = Set(tables.compactMap(\.schema).filter { !$0.isEmpty })
            if schemas.count > 1 {
                return schemas.sorted().map {
                    Namespace(path: [databaseName, $0], kind: .schema, isExpandable: true)
                }
            }
            return tables
                .sorted { $0.name < $1.name }
                .map {
                    Namespace(
                        path: [databaseName, $0.name],
                        kind: .table($0.tableKind),
                        isExpandable: false)
                }
        case .schema:
            let databaseName = parent.path[0]
            let schema = parent.path[1]
            return try await tables(inDatabaseNamed: databaseName)
                .filter { $0.schema == schema }
                .sorted { $0.name < $1.name }
                .map {
                    Namespace(
                        path: [databaseName, schema, $0.name],
                        kind: .table($0.tableKind),
                        isExpandable: false)
                }
        case .table:
            return []
        }
    }

    public func listColumns(of table: Namespace) async throws -> [ColumnMeta] {
        guard table.path.count >= 2 else { return [] }
        let databaseName = table.path[0]
        let schema = table.path.count >= 3 ? table.path[1] : nil
        let tableName = table.path.last ?? ""
        let match = try await tables(inDatabaseNamed: databaseName).first {
            $0.name == tableName && (schema == nil || $0.schema == schema)
        }
        guard let match else {
            throw DBError(kind: .queryFailed, message: "Unknown table \"\(tableName)\"")
        }
        return (match.fields ?? []).map {
            ColumnMeta(name: $0.name, dbTypeName: $0.typeName)
        }
    }

    /// Stores the toolbar-selected database; nil restores auto-targeting.
    /// Overrides the SQL default — Metabase has no session to switch.
    public func setActiveNamespace(_ name: String?) async throws {
        activeDatabaseName = name
    }

    // MARK: - Query execution

    public func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        guard case .sql(let sql) = query else {
            throw DBError(kind: .unsupported, message: "Metabase driver only accepts SQL")
        }
        let databaseID = try targetDatabaseID()

        var request = try makeRequest(path: "/api/dataset", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "database": databaseID,
            "type": "native",
            "native": ["query": sql],
        ])

        // Kept as an actor-held task so cancel aborts the transfer; Metabase
        // has no server-side cancel, the 2000-row `/api/dataset` cap bounds
        // the response instead.
        let requestTask = Task { [client] in try await client.send(request) }
        activeRequest = requestTask
        defer { activeRequest = nil }

        let data: Data
        do {
            let (body, response) = try await withTaskCancellationHandler {
                try await requestTask.value
            } onCancel: {
                requestTask.cancel()
            }
            try validate(response, data: body, failureKind: .queryFailed)
            data = body
        } catch let error as DBError {
            throw error
        } catch is CancellationError {
            throw DBError(kind: .cancelled, message: "Query cancelled")
        } catch let error as URLError where error.code == .cancelled {
            throw DBError(kind: .cancelled, message: "Query cancelled")
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: "Could not reach Metabase",
                underlying: String(describing: error))
        }

        let (columns, rows) = try MetabaseResponseParser.datasetResult(from: data)
        return Self.execution(columns: columns, rows: rows, pageSize: pageSize)
    }

    /// Delivers already-materialized rows in `pageSize`-bounded chunks.
    private static func execution(
        columns: [ColumnMeta], rows: [ResultRow], pageSize: Int
    ) -> QueryExecution {
        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>.makeStream()
        let size = max(1, pageSize)
        let producer = Task {
            do {
                if rows.isEmpty {
                    continuation.yield(QueryResultChunk(rows: [], isFinal: true))
                } else {
                    var index = 0
                    while index < rows.count {
                        try Task.checkCancellation()
                        let end = min(index + size, rows.count)
                        continuation.yield(QueryResultChunk(
                            rows: Array(rows[index..<end]),
                            isFinal: end == rows.count))
                        index = end
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: DBError(kind: .cancelled, message: "Query cancelled"))
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return QueryExecution(
            columns: columns,
            chunks: stream,
            cancel: { producer.cancel() })
    }

    private func targetDatabaseID() throws -> Int {
        if let activeDatabaseName {
            guard let id = databaseIDsByName[activeDatabaseName] else {
                throw DBError(
                    kind: .queryFailed,
                    message: "Unknown database \"\(activeDatabaseName)\"")
            }
            return id
        }
        if databases.count == 1 { return databases[0].id }
        throw DBError(kind: .queryFailed, message: "Select a database in the toolbar first.")
    }

    // MARK: - Metadata fetching

    private func loadDatabases() async throws {
        let request = try makeRequest(path: "/api/database")
        let data = try await send(request, failureKind: .connectionFailed)
        databases = try MetabaseResponseParser.databaseList(from: data)

        var counts: [String: Int] = [:]
        for database in databases { counts[database.name, default: 0] += 1 }
        databaseIDsByName = [:]
        orderedDatabaseNames = databases
            .map { database -> String in
                let display = counts[database.name]! > 1
                    ? "\(database.name) (\(database.id))"
                    : database.name
                databaseIDsByName[display] = database.id
                return display
            }
            .sorted()
    }

    private func tables(inDatabaseNamed name: String) async throws -> [MetabaseTable] {
        if databases.isEmpty { try await loadDatabases() }
        guard let id = databaseIDsByName[name] else {
            throw DBError(kind: .queryFailed, message: "Unknown database \"\(name)\"")
        }
        if let cached = metadataByDatabaseID[id] { return cached.tables ?? [] }
        let request = try makeRequest(path: "/api/database/\(id)/metadata")
        let data = try await send(request, failureKind: .connectionFailed)
        let metadata: MetabaseDatabaseMetadata
        do {
            metadata = try JSONDecoder().decode(MetabaseDatabaseMetadata.self, from: data)
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not parse metadata for \"\(name)\"",
                underlying: String(describing: error))
        }
        metadataByDatabaseID[id] = metadata
        return metadata.tables ?? []
    }

    // MARK: - HTTP plumbing

    private func makeRequest(path: String, method: String = "GET") throws -> URLRequest {
        guard let host = config.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            throw DBError(kind: .connectionFailed, message: "No Metabase URL configured")
        }
        var base = host.contains("://") ? host : "https://\(host)"
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw DBError(kind: .connectionFailed, message: "Invalid Metabase URL \"\(host)\"")
        }

        guard let token = config.password?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw DBError(
                kind: .authenticationExpired,
                message: "Not signed in to Metabase — sign in to create a session")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Metabase-Session")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest, failureKind: DBError.Kind) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.send(request)
        } catch let error as DBError {
            throw error
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not reach Metabase",
                underlying: String(describing: error))
        }
        try validate(response, data: data, failureKind: failureKind)
        return data
    }

    private func validate(
        _ response: HTTPURLResponse, data: Data, failureKind: DBError.Kind
    ) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw DBError(
                kind: .authenticationExpired,
                message: "Metabase session expired — please sign in again")
        default:
            let detail = MetabaseResponseParser.errorMessage(from: data)
            throw DBError(
                kind: failureKind,
                message: detail ?? "Metabase returned HTTP \(response.statusCode)",
                underlying: detail == nil ? nil : "HTTP \(response.statusCode)")
        }
    }
}
