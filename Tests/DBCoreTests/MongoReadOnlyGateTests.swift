import Foundation
import Testing

@testable import DBCore

@Suite struct MongoReadOnlyGateTests {

    @Test func findAndCountAlwaysPass() throws {
        try MongoReadOnlyGate.validate(operation: .find, body: #"{"status": "active"}"#)
        try MongoReadOnlyGate.validate(operation: .count, body: "{}")
        try MongoReadOnlyGate.validate(operation: .find, body: "")
        // Filter documents can mention the stage names harmlessly.
        try MongoReadOnlyGate.validate(operation: .find, body: #"{"note": "$out"}"#)
    }

    @Test func readOnlyAggregatePasses() throws {
        try MongoReadOnlyGate.validate(
            operation: .aggregate,
            body: #"[{"$match": {"a": 1}}, {"$group": {"_id": "$b", "n": {"$sum": 1}}}]"#)
        try MongoReadOnlyGate.validate(operation: .aggregate, body: "[]")
        // "$out" as a *value* is fine; only keys are stages.
        try MongoReadOnlyGate.validate(
            operation: .aggregate, body: #"[{"$project": {"x": "$out"}}]"#)
    }

    @Test func outAndMergeRejected() {
        #expect(throws: MongoReadOnlyGate.Violation.self) {
            try MongoReadOnlyGate.validate(
                operation: .aggregate,
                body: #"[{"$match": {}}, {"$out": "other_collection"}]"#)
        }
        #expect(throws: MongoReadOnlyGate.Violation.self) {
            try MongoReadOnlyGate.validate(
                operation: .aggregate,
                body: #"[{"$merge": {"into": "target"}}]"#)
        }
    }

    @Test func nestedWritingStagesRejected() {
        // $facet sub-pipeline
        #expect(throws: MongoReadOnlyGate.Violation.self) {
            try MongoReadOnlyGate.validate(
                operation: .aggregate,
                body: #"[{"$facet": {"branch": [{"$out": "leak"}]}}]"#)
        }
        // $unionWith sub-pipeline
        #expect(throws: MongoReadOnlyGate.Violation.self) {
            try MongoReadOnlyGate.validate(
                operation: .aggregate,
                body: #"[{"$unionWith": {"coll": "c", "pipeline": [{"$merge": {"into": "t"}}]}}]"#)
        }
    }

    @Test func unparseableBodyRejected() {
        #expect(throws: MongoReadOnlyGate.Violation.self) {
            try MongoReadOnlyGate.validate(operation: .aggregate, body: "not json {{")
        }
    }
}
