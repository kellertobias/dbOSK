import DBCore
import Foundation
import QueryEditor

/// Bridges the session's schema caches to the completion engine: builds
/// `SchemaSnapshot` values synchronously and fills gaps (unlisted containers,
/// unfetched columns) asynchronously, invoking the given callback when fresh
/// data lands so the editor can re-run the completion.
@MainActor
final class SchemaCompletionProvider {
    private unowned let session: ConnectionSession

    init(session: ConnectionSession) {
        self.session = session
    }

    var identifierQuote: String { session.descriptor.identifierQuote }

    /// Current schema view from the caches. Containers the sidebar hasn't
    /// listed yet get a load kicked off, so completion warms up on first use
    /// without waiting for the user to expand the tree.
    func snapshot(onUpdate: @escaping @MainActor () -> Void) -> SchemaSnapshot {
        var tables: [SchemaSnapshot.Table] = []
        var containers: [[String]] = []
        var columns: [String: [ColumnMeta]] = [:]

        func walk(_ namespaces: [Namespace]) {
            for namespace in namespaces {
                switch namespace.kind {
                case .table:
                    tables.append(.init(path: namespace.path))
                    if let cached = session.columnCache[namespace.id] {
                        columns[SchemaSnapshot.key(namespace.path)] = cached
                    }
                case .database, .schema:
                    containers.append(namespace.path)
                    if let children = session.children[namespace.id] {
                        walk(children)
                    } else {
                        session.loadChildrenIfNeeded(namespace, onLoaded: onUpdate)
                    }
                }
            }
        }
        walk(session.rootNamespaces)
        return SchemaSnapshot(tables: tables, containers: containers, columns: columns)
    }

    /// Fetches columns for the tables the engine reported missing.
    func requestColumns(
        for paths: [[String]], onUpdate: @escaping @MainActor () -> Void
    ) {
        for path in paths {
            guard let table = findTable(path: path) else { continue }
            session.loadColumnsIfNeeded(of: table, onLoaded: onUpdate)
        }
    }

    private func findTable(path: [String]) -> Namespace? {
        for namespaces in session.children.values {
            if let match = namespaces.first(where: {
                $0.kind.isTable && $0.path == path
            }) {
                return match
            }
        }
        // Some drivers list tables directly at the root.
        return session.rootNamespaces.first { $0.kind.isTable && $0.path == path }
    }
}
