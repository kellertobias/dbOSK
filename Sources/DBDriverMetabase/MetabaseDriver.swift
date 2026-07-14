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

    public init(config: ResolvedConnectionConfig) throws {
        self.config = config
    }

    public func connect() async throws {
        throw DBError(kind: .unsupported, message: "Metabase driver not implemented yet")
    }

    public func disconnect() async {}

    public func listNamespaces(parent: Namespace?) async throws -> [Namespace] {
        throw DBError(kind: .unsupported, message: "Metabase driver not implemented yet")
    }

    public func listColumns(of table: Namespace) async throws -> [ColumnMeta] {
        throw DBError(kind: .unsupported, message: "Metabase driver not implemented yet")
    }

    public func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        throw DBError(kind: .unsupported, message: "Metabase driver not implemented yet")
    }

    public func setActiveNamespace(_ name: String?) async throws {
        throw DBError(kind: .unsupported, message: "Metabase driver not implemented yet")
    }
}
