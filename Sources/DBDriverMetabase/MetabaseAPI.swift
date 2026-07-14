import DBCore
import Foundation

// MARK: - API models

/// One entry from `GET /api/database` — a database Metabase itself connects to.
struct MetabaseDatabaseInfo: Decodable, Sendable {
    let id: Int
    let name: String
    let engine: String?
}

/// Field metadata inside `GET /api/database/:id/metadata`.
struct MetabaseField: Decodable, Sendable {
    let name: String
    let databaseType: String?
    let baseType: String?

    enum CodingKeys: String, CodingKey {
        case name
        case databaseType = "database_type"
        case baseType = "base_type"
    }

    /// Engine-native type when Metabase reports one, else the semantic
    /// `base_type` with its "type/" prefix stripped.
    var typeName: String {
        if let databaseType, !databaseType.isEmpty { return databaseType }
        guard let baseType else { return "" }
        return strippedBaseType(baseType)
    }
}

/// Strips the "type/" prefix Metabase prepends to semantic `base_type` values.
func strippedBaseType(_ baseType: String) -> String {
    baseType.hasPrefix("type/") ? String(baseType.dropFirst(5)) : baseType
}

/// Table metadata inside `GET /api/database/:id/metadata`.
struct MetabaseTable: Decodable, Sendable {
    let name: String
    let schema: String?
    let fields: [MetabaseField]?
    let isView: Bool?

    enum CodingKeys: String, CodingKey {
        case name, schema, fields
        case isView = "is_view"
    }

    var tableKind: TableKind { isView == true ? .view : .table }
}

struct MetabaseDatabaseMetadata: Decodable, Sendable {
    let tables: [MetabaseTable]?
}

// MARK: - Response parsing

enum MetabaseResponseParser {
    /// `GET /api/database` returns `{"data": [...]}` on newer Metabase and a
    /// bare array on older versions; accept both.
    static func databaseList(from data: Data) throws -> [MetabaseDatabaseInfo] {
        struct Envelope: Decodable { let data: [MetabaseDatabaseInfo] }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            return envelope.data
        }
        do {
            return try decoder.decode([MetabaseDatabaseInfo].self, from: data)
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not parse the Metabase database list",
                underlying: String(describing: error))
        }
    }

    /// Best-effort error message from a Metabase error body, which may be
    /// `{"message": ...}`, `{"error": ...}`, `{"errors": {...}}`, or plain text.
    static func errorMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
            if let message = dict["message"] as? String, !message.isEmpty { return message }
            if let error = dict["error"] as? String, !error.isEmpty { return error }
            if let errors = dict["errors"] as? [String: Any],
               let first = errors.sorted(by: { $0.key < $1.key }).first,
               let text = first.value as? String {
                return "\(first.key): \(text)"
            }
            return nil
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty, !text.hasPrefix("<")
        else { return nil }
        return String(text.prefix(300))
    }

    /// Columns and rows from a successful `POST /api/dataset` body; a
    /// top-level `"status": "failed"` (or non-null `error` field) becomes
    /// `.queryFailed`. Metabase may send an explicit `"error": null` on
    /// success, which counts as no error.
    static func datasetResult(from data: Data) throws -> (columns: [ColumnMeta], rows: [ResultRow]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DBError(kind: .queryFailed, message: "Unexpected response from Metabase")
        }
        let error = root["error"].flatMap { $0 is NSNull ? nil : $0 }
        if (root["status"] as? String) == "failed" || error != nil {
            throw DBError(kind: .queryFailed, message: (error as? String) ?? "Query failed")
        }
        guard let payload = root["data"] as? [String: Any] else {
            throw DBError(kind: .queryFailed, message: "Metabase response contained no result data")
        }

        let cols = payload["cols"] as? [[String: Any]] ?? []
        let columns = cols.enumerated().map { index, col -> ColumnMeta in
            let name = (col["name"] as? String)
                ?? (col["display_name"] as? String)
                ?? "col\(index)"
            let databaseType = col["database_type"] as? String
            let baseType = (col["base_type"] as? String).map(strippedBaseType)
            return ColumnMeta(name: name, dbTypeName: databaseType ?? baseType ?? "")
        }

        let rawRows = payload["rows"] as? [[Any]] ?? []
        let rows = rawRows.enumerated().map { index, raw in
            ResultRow(id: index, values: raw.map(DBValue.fromJSONObject))
        }
        return (columns, rows)
    }
}
