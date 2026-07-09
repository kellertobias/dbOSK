import Connections
import DBCore
import DBDriverPostgres
import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    /// Drivers with a working implementation; MySQL, MongoDB, SQLite follow.
    static let availableDrivers: [DriverDescriptor] = [
        PostgresDriver.descriptor
    ]

    var profiles: [ConnectionProfile] = []
    var activeSession: ConnectionSession?
    var connectionError: String?
    var isConnecting = false

    private let profileStore = ProfileStore()
    private let resolver = CredentialResolver()
    let keychain = KeychainStore()

    init() {
        profiles = (try? profileStore.load()) ?? []
    }

    func saveProfiles() {
        do {
            try profileStore.save(profiles)
        } catch {
            connectionError = "Could not save connections: \(error.localizedDescription)"
        }
    }

    func upsert(_ profile: ConnectionProfile, password: String?) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if case .keychain = profile.credentialSource, let password, !password.isEmpty {
            try? keychain.setPassword(password, for: profile.id)
        }
        saveProfiles()
    }

    func delete(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        try? keychain.deletePassword(for: profile.id)
        saveProfiles()
    }

    func connect(to profile: ConnectionProfile) async {
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        do {
            let config = try await resolver.resolve(profile)
            let driver = try makeDriver(profile: profile, config: config)
            try await driver.connect()
            activeSession = ConnectionSession(profile: profile, driver: driver)
        } catch {
            connectionError = String(describing: error)
        }
    }

    func disconnect() {
        let session = activeSession
        activeSession = nil
        Task { await session?.driver.disconnect() }
    }

    private func makeDriver(
        profile: ConnectionProfile, config: ResolvedConnectionConfig
    ) throws -> any DatabaseDriver {
        switch profile.driverID {
        case PostgresDriver.descriptor.id:
            return try PostgresDriver(config: config)
        default:
            throw DBError(
                kind: .unsupported,
                message: "Driver \(profile.driverID) is not implemented yet")
        }
    }
}

// MARK: - Session

@Observable
@MainActor
final class ConnectionSession: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let driver: any DatabaseDriver

    enum DetailMode: String, CaseIterable {
        case query = "Query"
        case table = "Table"
    }

    var rootNamespaces: [Namespace] = []
    var children: [Namespace.ID: [Namespace]] = [:]
    var sidebarError: String?
    var queryTab: QueryTab
    var detailMode: DetailMode = .query
    var tableBrowser: TableBrowser

    init(profile: ConnectionProfile, driver: any DatabaseDriver) {
        self.profile = profile
        self.driver = driver
        self.queryTab = QueryTab(driver: driver)
        self.tableBrowser = TableBrowser(driver: driver)
    }

    /// Sidebar selection: in Table mode it targets the browser; in Query mode
    /// double-click inserts a query (handled in the view).
    func selectTable(_ namespace: Namespace) {
        guard case .table = namespace.kind else { return }
        tableBrowser.select(namespace)
    }

    func loadRoot() async {
        do {
            rootNamespaces = try await driver.listNamespaces(parent: nil)
        } catch {
            sidebarError = String(describing: error)
        }
    }

    func loadChildren(of namespace: Namespace) async {
        guard children[namespace.id] == nil else { return }
        do {
            children[namespace.id] = try await driver.listNamespaces(parent: namespace)
        } catch {
            sidebarError = String(describing: error)
        }
    }
}

// MARK: - Query tab

@Observable
@MainActor
final class QueryTab {
    enum RunState: Equatable {
        case idle
        case running
        case streaming
        case done(rowCount: Int, elapsed: TimeInterval)
        case failed(String)
        case cancelled
    }

    var queryText: String = ""
    var runState: RunState = .idle
    var columns: [ColumnMeta] = []
    var rows: [ResultRow] = []
    /// Incremented whenever rows/columns change, so AppKit views know to reload.
    var resultVersion = 0

    private let driver: any DatabaseDriver
    private var runTask: Task<Void, Never>?
    private var cancelHandler: (@Sendable () async -> Void)?

    var pageSize = 500

    init(driver: any DatabaseDriver) {
        self.driver = driver
    }

    func run() {
        guard runState != .running, runState != .streaming else { return }
        let sql = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }

        runState = .running
        columns = []
        rows = []
        resultVersion += 1
        let started = Date()

        runTask = Task { [driver, pageSize] in
            do {
                let execution = try await driver.execute(.sql(sql), pageSize: pageSize)
                self.cancelHandler = execution.cancel
                self.columns = execution.columns
                self.runState = .streaming
                self.resultVersion += 1
                for try await chunk in execution.chunks {
                    self.rows.append(contentsOf: chunk.rows)
                    self.resultVersion += 1
                }
                self.runState = .done(
                    rowCount: self.rows.count,
                    elapsed: Date().timeIntervalSince(started))
            } catch let error as DBError where error.kind == .cancelled {
                self.runState = .cancelled
            } catch {
                self.runState = .failed(String(describing: error))
            }
            self.cancelHandler = nil
        }
    }

    func stop() {
        let handler = cancelHandler
        runTask?.cancel()
        Task { await handler?() }
    }
}

extension DBError.Kind: Equatable {}

// MARK: - Table browser (Full Table mode)

@Observable
@MainActor
final class TableBrowser {
    var table: Namespace?
    var availableColumns: [ColumnMeta] = []
    /// Selected column names; empty = all columns.
    var selectedColumns: Set<String> = []
    var whereClause = ""
    var offset = 0
    var limit = 100
    var columnsError: String?

    /// Executes the built query; reuses the streaming runner.
    let resultTab: QueryTab

    private let driver: any DatabaseDriver

    init(driver: any DatabaseDriver) {
        self.driver = driver
        self.resultTab = QueryTab(driver: driver)
    }

    func select(_ namespace: Namespace) {
        guard namespace != table else { return }
        table = namespace
        availableColumns = []
        selectedColumns = []
        whereClause = ""
        offset = 0
        columnsError = nil
        Task {
            do {
                availableColumns = try await driver.listColumns(of: namespace)
            } catch {
                columnsError = String(describing: error)
            }
            load()
        }
    }

    func toggleColumn(_ name: String) {
        if selectedColumns.contains(name) {
            selectedColumns.remove(name)
        } else {
            selectedColumns.insert(name)
        }
    }

    var builtSQL: String? {
        guard let table else { return nil }
        let target = table.path.map { quoteIdentifier($0) }.joined(separator: ".")
        let columns: String
        if selectedColumns.isEmpty {
            columns = "*"
        } else {
            // Preserve table column order rather than selection order.
            columns = availableColumns
                .map(\.name)
                .filter { selectedColumns.contains($0) }
                .map { quoteIdentifier($0) }
                .joined(separator: ", ")
        }
        var sql = "SELECT \(columns) FROM \(target)"
        let condition = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !condition.isEmpty {
            sql += " WHERE \(condition)"
        }
        sql += " LIMIT \(max(limit, 1)) OFFSET \(max(offset, 0))"
        return sql
    }

    func load() {
        guard let sql = builtSQL else { return }
        resultTab.queryText = sql
        resultTab.run()
    }

    func nextPage() {
        offset += limit
        load()
    }

    func previousPage() {
        offset = max(0, offset - limit)
        load()
    }

    private func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
