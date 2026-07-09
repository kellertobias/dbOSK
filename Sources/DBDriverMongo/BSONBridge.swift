import BSON
import DBCore
import Foundation

/// Conversions between JSON text, BSON documents, and the app's DBValue model.
enum BSONBridge {
    // MARK: JSON → BSON

    static func document(fromJSON json: String) throws -> Document {
        let object = try jsonObject(json)
        guard let dict = object as? [String: Any] else {
            throw DBError(kind: .queryFailed, message: "Expected a JSON object ({...})")
        }
        return documentValue(dict)
    }

    static func pipeline(fromJSON json: String) throws -> [Document] {
        let object = try jsonObject(json)
        guard let array = object as? [Any] else {
            throw DBError(kind: .queryFailed, message: "Expected a JSON array of stages ([...])")
        }
        return try array.map { stage in
            guard let dict = stage as? [String: Any] else {
                throw DBError(kind: .queryFailed, message: "Each pipeline stage must be an object")
            }
            return documentValue(dict)
        }
    }

    private static func jsonObject(_ json: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(
                with: Data(json.utf8), options: [.fragmentsAllowed])
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: "Invalid JSON: \(error.localizedDescription)")
        }
    }

    private static func documentValue(_ dict: [String: Any]) -> Document {
        // Extended-JSON convenience: {"$oid": "..."} becomes an ObjectId.
        if dict.count == 1, let hex = dict["$oid"] as? String,
           let objectId = ObjectId(hex) {
            var wrapper = Document()
            wrapper["$oid"] = objectId
            return wrapper
        }
        var document = Document()
        for (key, value) in dict {
            document[key] = primitive(fromJSON: value)
        }
        return document
    }

    private static func primitive(fromJSON value: Any) -> Primitive? {
        switch value {
        case is NSNull:
            return Null()
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if CFNumberIsFloatType(number) { return number.doubleValue }
            return number.intValue
        case let string as String:
            return string
        case let dict as [String: Any]:
            if dict.count == 1, let hex = dict["$oid"] as? String,
               let objectId = ObjectId(hex) {
                return objectId
            }
            return documentValue(dict)
        case let array as [Any]:
            var document = Document(isArray: true)
            for element in array {
                document.append(primitive(fromJSON: element) ?? Null())
            }
            return document
        default:
            return String(describing: value)
        }
    }

    // MARK: BSON → DBValue

    static func dbValue(_ document: Document) -> DBValue {
        if document.isArray {
            return .array(document.values.map { dbValue(primitive: $0) })
        }
        var result: [String: DBValue] = [:]
        for key in document.keys {
            result[key] = dbValue(primitive: document[key])
        }
        return .document(result)
    }

    static func dbValue(primitive: Primitive?) -> DBValue {
        switch primitive {
        case nil, is Null:
            return .null
        case let string as String:
            return .string(string)
        case let int as Int:
            return .int(Int64(int))
        case let int as Int32:
            return .int(Int64(int))
        case let double as Double:
            return .double(double)
        case let bool as Bool:
            return .bool(bool)
        case let date as Date:
            return .date(date)
        case let objectId as ObjectId:
            return .string(objectId.hexString)
        case let decimal as Decimal128:
            // The BSON library's Decimal128 is a stub without string conversion.
            return .unsupported(typeName: "decimal128", text: String(describing: decimal))
        case let binary as Binary:
            return .bytes(binary.data)
        case let regex as RegularExpression:
            return .string("/\(regex.pattern)/\(regex.options)")
        case let timestamp as Timestamp:
            return .string("Timestamp(\(timestamp.timestamp), \(timestamp.increment))")
        case let document as Document:
            return dbValue(document)
        case let value?:
            return .unsupported(
                typeName: typeName(value), text: String(describing: value))
        }
    }

    static func typeName(_ primitive: Primitive?) -> String {
        switch primitive {
        case nil, is Null: return "null"
        case is String: return "string"
        case is Int, is Int32: return "int"
        case is Double: return "double"
        case is Bool: return "bool"
        case is Date: return "date"
        case is ObjectId: return "objectId"
        case is Decimal128: return "decimal"
        case is Binary: return "binary"
        case let document as Document: return document.isArray ? "array" : "document"
        default: return String(describing: type(of: primitive!))
        }
    }
}
