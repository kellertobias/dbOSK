import Foundation

/// Validates that a Mongo operation submitted by an MCP client cannot write.
/// `find` and `count` are inherently read-only; `aggregate` pipelines can
/// write through `$out` and `$merge`, which may hide inside `$facet`,
/// `$unionWith`, or `$lookup` sub-pipelines — so the whole body is scanned
/// recursively. Unparseable bodies are rejected (fail closed); the drivers
/// would reject them anyway.
public enum MongoReadOnlyGate {

    public struct Violation: Error, Sendable, Equatable, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
        public init(reason: String) { self.reason = reason }
    }

    static let deniedStages: Set<String> = ["$out", "$merge"]

    public static func validate(operation: MongoOperation, body: String) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }

        guard let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else {
            throw Violation(reason:
                "Body is not valid JSON; refusing to run an unparseable \(operation.rawValue) body.")
        }

        switch operation {
        case .find, .count:
            return  // Filter documents cannot write regardless of content.
        case .aggregate:
            if let stage = firstDeniedKey(in: json) {
                throw Violation(reason:
                    "Aggregation stage '\(stage)' writes to a collection and is not allowed "
                    + "in read-only MCP queries.")
            }
        }
    }

    private static func firstDeniedKey(in json: Any) -> String? {
        if let object = json as? [String: Any] {
            for (key, value) in object {
                if deniedStages.contains(key) { return key }
                if let nested = firstDeniedKey(in: value) { return nested }
            }
        } else if let array = json as? [Any] {
            for element in array {
                if let nested = firstDeniedKey(in: element) { return nested }
            }
        }
        return nil
    }
}
