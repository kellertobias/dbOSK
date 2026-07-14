import DBCore
import Foundation

/// Transport abstraction for the Metabase REST API, injectable for tests.
/// Implementations return the raw body plus the HTTP response; status-code
/// interpretation (401 → re-auth, error-body extraction) stays in the driver.
public protocol MetabaseHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default client backed by an ephemeral `URLSession`. Honors cooperative
/// Task cancellation (URLSession aborts the transfer when the awaiting task
/// is cancelled).
public struct URLSessionMetabaseHTTPClient: MetabaseHTTPClient {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DBError(kind: .connectionFailed, message: "Non-HTTP response from Metabase")
        }
        return (data, http)
    }
}
