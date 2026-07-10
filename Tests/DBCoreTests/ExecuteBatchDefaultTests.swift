import Foundation
import Testing

@testable import DBCore

/// Exercises the protocol-extension `executeBatch` (the BEGIN/COMMIT path
/// Postgres and MySQL inherit) against a scripted in-memory driver.
@Suite struct ExecuteBatchDefaultTests {
    /// SQL driver double: records every statement, fails on demand either at
    /// `execute()` (prepare error) or inside the chunk stream (runtime error).
    final class ScriptedSQLDriver: DatabaseDriver, @unchecked Sendable {
        static let descriptor = DriverDescriptor(
            id: "fake-sql", displayName: "FakeSQL", queryLanguage: .sql,
            defaultPort: nil, supportsStreaming: false, supportsServerSideCancel: false,
            sqlDialect: .postgres, supportsTableEditing: true, supportsDDL: true)

        private let lock = NSLock()
        private var _executed: [String] = []
        /// Statements that throw from execute() itself.
        var failing: Set<String> = []
        /// Statements whose chunk stream finishes throwing.
        var streamFailing: Set<String> = []
        /// Affected counts reported in the final chunk.
        var affectedCounts: [String: Int] = [:]

        var executed: [String] { lock.withLock { _executed } }

        init() {}
        init(config: ResolvedConnectionConfig) throws {}
        func connect() async throws {}
        func disconnect() async {}
        func listNamespaces(parent: Namespace?) async throws -> [Namespace] { [] }
        func listColumns(of table: Namespace) async throws -> [ColumnMeta] { [] }

        func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
            guard case .sql(let sql) = query else {
                throw DBError(kind: .unsupported, message: "SQL only")
            }
            lock.withLock { _executed.append(sql) }
            if failing.contains(sql) {
                throw DBError(kind: .queryFailed, message: "prepare failed: \(sql)")
            }
            let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
                .makeStream()
            if streamFailing.contains(sql) {
                continuation.finish(
                    throwing: DBError(kind: .queryFailed, message: "runtime failed: \(sql)"))
            } else {
                continuation.yield(QueryResultChunk(
                    rows: [], isFinal: true, affectedCount: affectedCounts[sql]))
                continuation.finish()
            }
            return QueryExecution(columns: [], chunks: stream, cancel: {})
        }
    }

    /// Non-SQL driver double: `executeBatch` must refuse before running anything.
    final class ScriptedRedisDriver: DatabaseDriver, @unchecked Sendable {
        static let descriptor = DriverDescriptor(
            id: "fake-redis", displayName: "FakeRedis", queryLanguage: .redis,
            defaultPort: nil, supportsStreaming: false, supportsServerSideCancel: false,
            identifierQuote: "")

        init() {}
        init(config: ResolvedConnectionConfig) throws {}
        func connect() async throws {}
        func disconnect() async {}
        func listNamespaces(parent: Namespace?) async throws -> [Namespace] { [] }
        func listColumns(of table: Namespace) async throws -> [ColumnMeta] { [] }
        func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
            Issue.record("execute must not be called")
            throw DBError(kind: .unsupported, message: "unreachable")
        }
    }

    @Test func wrapsStatementsInTransaction() async throws {
        let driver = ScriptedSQLDriver()
        driver.affectedCounts = ["UPDATE t SET a = 1": 3]

        let results = try await driver.executeBatch([
            "UPDATE t SET a = 1",
            "DELETE FROM t WHERE b = 2",
        ])
        #expect(driver.executed == [
            "BEGIN",
            "UPDATE t SET a = 1",
            "DELETE FROM t WHERE b = 2",
            "COMMIT",
        ])
        #expect(results.map(\.affectedCount) == [3, nil])
    }

    @Test func rollsBackWhenAStatementFails() async throws {
        let driver = ScriptedSQLDriver()
        driver.failing = ["s2"]

        var batchError: BatchError?
        do {
            _ = try await driver.executeBatch(["s1", "s2", "s3"])
        } catch let error as BatchError {
            batchError = error
        }
        #expect(driver.executed == ["BEGIN", "s1", "s2", "ROLLBACK"])
        #expect(batchError?.statementIndex == 1)
        #expect(batchError?.statement == "s2")
        #expect(batchError?.rolledBack == true)
        #expect(batchError?.underlying.kind == .queryFailed)
    }

    @Test func streamErrorsAlsoRollBack() async throws {
        // Runtime failures surface through the chunk stream, not execute().
        let driver = ScriptedSQLDriver()
        driver.streamFailing = ["s1"]

        var batchError: BatchError?
        do {
            _ = try await driver.executeBatch(["s1"])
        } catch let error as BatchError {
            batchError = error
        }
        #expect(driver.executed == ["BEGIN", "s1", "ROLLBACK"])
        #expect(batchError?.statementIndex == 0)
        #expect(batchError?.rolledBack == true)
    }

    @Test func reportsFailedRollback() async throws {
        let driver = ScriptedSQLDriver()
        driver.failing = ["s1", "ROLLBACK"]

        var batchError: BatchError?
        do {
            _ = try await driver.executeBatch(["s1"])
        } catch let error as BatchError {
            batchError = error
        }
        #expect(batchError?.rolledBack == false)
    }

    @Test func commitFailureIsIndexedPastTheStatements() async throws {
        let driver = ScriptedSQLDriver()
        driver.failing = ["COMMIT"]

        var batchError: BatchError?
        do {
            _ = try await driver.executeBatch(["s1"])
        } catch let error as BatchError {
            batchError = error
        }
        #expect(driver.executed == ["BEGIN", "s1", "COMMIT", "ROLLBACK"])
        #expect(batchError?.statementIndex == 1)
        #expect(batchError?.statement == "COMMIT")
        #expect(batchError?.rolledBack == true)
    }

    @Test func nonSQLDriverRefusesWithoutExecuting() async throws {
        let driver = ScriptedRedisDriver()
        var kind: DBError.Kind?
        do {
            _ = try await driver.executeBatch(["SET k v"])
        } catch let error as DBError {
            kind = error.kind
        }
        #expect(kind == .unsupported)
    }
}
