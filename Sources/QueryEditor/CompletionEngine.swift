import DBCore
import Foundation

// MARK: - Schema snapshot

/// Immutable value-type view of the schema the engine completes against.
/// Built on the MainActor from the session caches; the engine itself is pure.
public struct SchemaSnapshot: Sendable {
    public struct Table: Sendable {
        /// Full sidebar path, e.g. ["mydb", "public", "users"].
        public let path: [String]

        public init(path: [String]) {
            self.path = path
        }

        public var name: String { path.last ?? "" }
    }

    public let tables: [Table]
    /// Schema/database container paths (for `schema.` completion).
    public let containers: [[String]]
    /// Cached columns keyed by `SchemaSnapshot.key(path)` of the full table path.
    public let columns: [String: [ColumnMeta]]

    public init(
        tables: [Table], containers: [[String]] = [],
        columns: [String: [ColumnMeta]] = [:]
    ) {
        self.tables = tables
        self.containers = containers
        self.columns = columns
    }

    /// Canonical case-insensitive key for a table path.
    public static func key(_ path: [String]) -> String {
        path.map { $0.lowercased() }.joined(separator: "\u{1F}")
    }
}

// MARK: - Results

public struct CompletionCandidate: Equatable, Sendable {
    public enum Kind: Sendable {
        case table, column, keyword, schema
    }

    public let kind: Kind
    /// Display name (the schema's exact spelling).
    public let label: String
    /// Secondary display text: column type, owning table, or kind.
    public let detail: String
    /// Text committed into the editor, quoted when the dialect requires it.
    public let insertText: String
}

public struct CompletionResult {
    public let items: [CompletionCandidate]
    public let replacementRange: NSRange
    /// Full paths of referenced tables whose columns are not in the snapshot
    /// yet — the caller fetches these and re-runs the completion.
    public let missingColumnTables: [[String]]
}

// MARK: - Engine

/// Pure, synchronous completion over a `SchemaSnapshot`. All async work
/// (fetching columns, listing tables) happens outside via
/// `CompletionResult.missingColumnTables`.
public struct CompletionEngine {
    private let identifierQuote: String
    private let maxItems = 50

    public init(identifierQuote: String) {
        self.identifierQuote = identifierQuote
    }

    /// Candidates at `cursorUTF16`, or nil when nothing should show
    /// (inside strings/comments, or an empty prefix without an explicit
    /// request or member access).
    public func complete(
        text: String, cursorUTF16: Int, schema: SchemaSnapshot, explicit: Bool
    ) -> CompletionResult? {
        guard let context = SQLContextAnalyzer.context(in: text, cursorUTF16: cursorUTF16)
        else { return nil }

        let references = SQLContextAnalyzer.referencedTables(in: text)
        var missing: [[String]] = []
        var items: [CompletionCandidate] = []

        switch context.kind {
        case .memberAccess(let qualifier, let prefix):
            items = memberCandidates(
                qualifier: qualifier, prefix: prefix, schema: schema,
                references: references, missing: &missing)

        case .tableName(let prefix):
            guard explicit || !prefix.isEmpty else { return nil }
            items = rank(tableCandidates(schema: schema), prefix: prefix)
                + rank(containerCandidates(schema: schema), prefix: prefix)

        case .identifier(let prefix):
            guard explicit || !prefix.isEmpty else { return nil }
            items = rank(
                referencedColumnCandidates(
                    schema: schema, references: references, missing: &missing),
                prefix: prefix)
            items += rank(tableCandidates(schema: schema), prefix: prefix)
            items += rank(containerCandidates(schema: schema), prefix: prefix)
            if prefix.count >= 2 {
                items += rank(keywordCandidates(), prefix: prefix)
            }
        }

        // Nothing to show and nothing on the way: no popup.
        if items.isEmpty && missing.isEmpty { return nil }
        return CompletionResult(
            items: Array(items.prefix(maxItems)),
            replacementRange: context.replacementRange,
            missingColumnTables: missing)
    }

    // MARK: Candidate sources

    private func memberCandidates(
        qualifier: [String], prefix: String, schema: SchemaSnapshot,
        references: [TableReference], missing: inout [[String]]
    ) -> [CompletionCandidate] {
        // 1. Alias of a referenced table.
        if qualifier.count == 1,
           let reference = references.first(where: {
               $0.alias?.caseInsensitiveCompare(qualifier[0]) == .orderedSame
           }),
           let table = resolveTable(path: reference.path, in: schema)
        {
            return rank(
                columnCandidates(of: table, schema: schema, missing: &missing),
                prefix: prefix)
        }

        // 2. A table (by trailing path match: `users.` or `public.users.`).
        if let table = resolveTable(path: qualifier, in: schema) {
            return rank(
                columnCandidates(of: table, schema: schema, missing: &missing),
                prefix: prefix)
        }

        // 3. A schema/database container: offer its tables.
        let tables = schema.tables.filter { pathHasSuffix($0.path.dropLast(), qualifier) }
        if !tables.isEmpty {
            return rank(
                tables.map { candidate(table: $0) },
                prefix: prefix)
        }

        return []
    }

    private func resolveTable(path: [String], in schema: SchemaSnapshot)
        -> SchemaSnapshot.Table?
    {
        schema.tables.first { pathHasSuffix($0.path[...], path) }
    }

    /// True when `path` ends with `suffix`, case-insensitively.
    private func pathHasSuffix(_ path: ArraySlice<String>, _ suffix: [String]) -> Bool {
        guard path.count >= suffix.count, !suffix.isEmpty else { return false }
        return zip(path.suffix(suffix.count), suffix).allSatisfy {
            $0.caseInsensitiveCompare($1) == .orderedSame
        }
    }

    private func columnCandidates(
        of table: SchemaSnapshot.Table, schema: SchemaSnapshot,
        missing: inout [[String]]
    ) -> [CompletionCandidate] {
        guard let columns = schema.columns[SchemaSnapshot.key(table.path)] else {
            missing.append(table.path)
            return []
        }
        return columns.map {
            CompletionCandidate(
                kind: .column, label: $0.name,
                detail: "\($0.dbTypeName) · \(table.name)",
                insertText: quoted($0.name))
        }
    }

    private func referencedColumnCandidates(
        schema: SchemaSnapshot, references: [TableReference],
        missing: inout [[String]]
    ) -> [CompletionCandidate] {
        var seen = Set<String>()
        var result: [CompletionCandidate] = []
        for reference in references {
            guard let table = resolveTable(path: reference.path, in: schema),
                  seen.insert(SchemaSnapshot.key(table.path)).inserted
            else { continue }
            result += columnCandidates(of: table, schema: schema, missing: &missing)
        }
        return result
    }

    private func tableCandidates(schema: SchemaSnapshot) -> [CompletionCandidate] {
        schema.tables.map(candidate(table:))
    }

    private func candidate(table: SchemaSnapshot.Table) -> CompletionCandidate {
        CompletionCandidate(
            kind: .table, label: table.name,
            detail: table.path.dropLast().joined(separator: "."),
            insertText: quoted(table.name))
    }

    private func containerCandidates(schema: SchemaSnapshot) -> [CompletionCandidate] {
        schema.containers.compactMap { path in
            guard let name = path.last else { return nil }
            return CompletionCandidate(
                kind: .schema, label: name,
                detail: path.dropLast().joined(separator: "."),
                insertText: quoted(name))
        }
    }

    private func keywordCandidates() -> [CompletionCandidate] {
        SQLSyntax.keywords.map {
            CompletionCandidate(kind: .keyword, label: $0, detail: "", insertText: $0)
        }
    }

    // MARK: Ranking & quoting

    /// Case-insensitive prefix matches (alphabetical) before substring
    /// matches (alphabetical); non-matches dropped. Empty prefix keeps the
    /// source order.
    private func rank(_ candidates: [CompletionCandidate], prefix: String)
        -> [CompletionCandidate]
    {
        guard !prefix.isEmpty else {
            return candidates.sorted { $0.label.lowercased() < $1.label.lowercased() }
        }
        let needle = prefix.lowercased()
        var prefixMatches: [CompletionCandidate] = []
        var substringMatches: [CompletionCandidate] = []
        for candidate in candidates {
            let label = candidate.label.lowercased()
            if label.hasPrefix(needle) {
                prefixMatches.append(candidate)
            } else if label.contains(needle) {
                substringMatches.append(candidate)
            }
        }
        let byLabel: (CompletionCandidate, CompletionCandidate) -> Bool = {
            $0.label.lowercased() < $1.label.lowercased()
        }
        return prefixMatches.sorted(by: byLabel) + substringMatches.sorted(by: byLabel)
    }

    /// Wraps in the dialect's identifier quote only when the bare spelling
    /// would be ambiguous or invalid. Mirrors `DriverDescriptor.quoted`.
    private func quoted(_ identifier: String) -> String {
        guard !identifierQuote.isEmpty, SQLSyntax.needsQuoting(identifier)
        else { return identifier }
        let escaped = identifier.replacingOccurrences(
            of: identifierQuote, with: identifierQuote + identifierQuote)
        return identifierQuote + escaped + identifierQuote
    }
}
