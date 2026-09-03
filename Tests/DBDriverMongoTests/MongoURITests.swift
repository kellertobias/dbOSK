import DBCore
import Foundation
import Testing

@testable import DBDriverMongo

@Suite struct MongoURITests {
    private func queryItems(_ uri: String) -> [String: String] {
        let items = URLComponents(string: uri)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func defaultsAuthSourceToAdmin() {
        let uri = MongoDriver.buildURI(
            ResolvedConnectionConfig(host: "h", user: "u", password: "p", database: "orders"))
        #expect(uri.hasPrefix("mongodb://u:p@h:27017/orders"))
        #expect(queryItems(uri)["authSource"] == "admin")
    }

    @Test func usesAuthenticationDatabaseAsAuthSource() {
        let uri = MongoDriver.buildURI(
            ResolvedConnectionConfig(
                host: "h", user: "u", password: "p", database: "orders",
                authenticationDatabase: "users", tls: .required))
        #expect(uri.contains("/orders?"))
        let items = queryItems(uri)
        #expect(items["authSource"] == "users")
        #expect(items["tls"] == "true")
    }

    @Test func emptyAuthenticationDatabaseFallsBackToAdmin() {
        let uri = MongoDriver.buildURI(
            ResolvedConnectionConfig(
                host: "h", user: "u", database: "orders", authenticationDatabase: ""))
        #expect(queryItems(uri)["authSource"] == "admin")
    }

    @Test func noUserMeansNoAuthSource() {
        let uri = MongoDriver.buildURI(
            ResolvedConnectionConfig(host: "h", database: "orders", authenticationDatabase: "x"))
        #expect(queryItems(uri)["authSource"] == nil)
    }

    @Test func explicitURIWins() {
        let uri = MongoDriver.buildURI(
            ResolvedConnectionConfig(authenticationDatabase: "q", uri: "mongodb://x/y?authSource=z"))
        #expect(uri == "mongodb://x/y?authSource=z")
    }
}
