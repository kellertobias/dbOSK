import Connections
import DBCore
import Foundation
import MCPServer

/// Bridges `AppModel.sessions` to the MCP server: joins each active session
/// with its `MCPAccessConfig` and hands out the session's dedicated
/// read-only driver. Redis/DynamoDB (and other non-SQL/non-Mongo engines)
/// are never exposed.
@MainActor
final class AppModelMCPAdapter: MCPConnectionProvider {
    private weak var appModel: AppModel?
    private weak var controller: MCPServerController?

    init(appModel: AppModel, controller: MCPServerController) {
        self.appModel = appModel
        self.controller = controller
    }

    func connections() async -> [ExposedConnection] {
        guard let appModel, let controller else { return [] }
        return appModel.sessions.compactMap { (profileID, session) in
            let descriptor = session.descriptor
            switch descriptor.queryLanguage {
            case .sql:
                // Engines without a fixed dialect (Metabase) can't pass the
                // dialect-aware read-only gate; keep them unexposed.
                guard descriptor.sqlDialect != nil else { return nil }
            case .mongo:
                break
            case .redis, .partiql:
                return nil
            }
            return ExposedConnection(
                id: profileID.uuidString,
                name: session.profile.name,
                engine: descriptor.displayName,
                queryLanguage: descriptor.queryLanguage,
                sqlDialect: descriptor.sqlDialect,
                explainSupport: descriptor.explainSupport,
                access: controller.access(for: profileID),
                driver: { try await session.mcpReadOnlyDriver() })
        }
    }
}
