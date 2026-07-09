import Foundation

/// Driver-agnostic value model. All renderers and exporters consume only `DBValue`;
/// drivers own the mapping from wire types.
public enum DBValue: Sendable, Hashable {
    case null
    case string(String)
    case int(Int64)
    case double(Double)
    /// Exact numerics (NUMERIC, Decimal128) kept as text to avoid precision loss.
    case decimal(String)
    case bool(Bool)
    case date(Date)
    case bytes(Data)
    case uuid(UUID)
    case document([String: DBValue])
    case array([DBValue])
    /// Graceful fallback for types we don't map yet.
    case unsupported(typeName: String, text: String)
}

extension DBValue {
    /// Compact single-line representation for table cells.
    public var displayString: String {
        switch self {
        case .null: return "NULL"
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .decimal(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return Self.isoString(d)
        case .bytes(let data): return "0x… (\(data.count) bytes)"
        case .uuid(let u): return u.uuidString.lowercased()
        case .document: return jsonString(prettyPrinted: false)
        case .array: return jsonString(prettyPrinted: false)
        case .unsupported(_, let text): return text
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    static func isoString(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day()
            .timeZone(separator: .omitted).time(includingFractionalSeconds: true))
    }
}

// MARK: - JSON encoding

extension DBValue {
    /// JSON-compatible representation (for JSON export and document previews).
    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d.isFinite ? d : String(d)
        case .decimal(let s): return s
        case .bool(let b): return b
        case .date(let d): return Self.isoString(d)
        case .bytes(let data): return data.base64EncodedString()
        case .uuid(let u): return u.uuidString.lowercased()
        case .document(let dict): return dict.mapValues { $0.jsonObject }
        case .array(let items): return items.map { $0.jsonObject }
        case .unsupported(_, let text): return text
        }
    }

    public func jsonString(prettyPrinted: Bool) -> String {
        let object = jsonObject
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if prettyPrinted { options.insert(.prettyPrinted) }
        guard JSONSerialization.isValidJSONObject([object]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let string = String(data: data, encoding: .utf8)
        else { return displayString }
        return string
    }
}
