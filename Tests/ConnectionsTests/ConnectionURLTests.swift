import DBCore
import Foundation
import Testing

@testable import Connections

@Suite struct ConnectionURLTests {
    @Test func postgresURLWithEveryComponent() throws {
        let parsed = try #require(
            ConnectionURL.parse("postgres://me:s3cret@db.example.com:5433/app?sslmode=require"))
        #expect(parsed.driverID == "postgres")
        #expect(parsed.host == "db.example.com")
        #expect(parsed.port == 5433)
        #expect(parsed.user == "me")
        #expect(parsed.password == "s3cret")
        #expect(parsed.database == "app")
        #expect(parsed.tls == .required)
    }

    @Test func missingComponentsStayNil() throws {
        let parsed = try #require(ConnectionURL.parse("postgresql://localhost"))
        #expect(parsed.driverID == "postgres")
        #expect(parsed.host == "localhost")
        #expect(parsed.port == nil)
        #expect(parsed.user == nil)
        #expect(parsed.password == nil)
        #expect(parsed.database == nil)
        #expect(parsed.tls == nil)
    }

    @Test func percentEncodedCredentialsAreDecoded() throws {
        let parsed = try #require(
            ConnectionURL.parse("mysql://a%40b:p%40ss%2Fword@127.0.0.1:3306/shop"))
        #expect(parsed.driverID == "mysql")
        #expect(parsed.user == "a@b")
        #expect(parsed.password == "p@ss/word")
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.database == "shop")
    }

    @Test func unescapedAtSignInPasswordSplitsAtTheLastOne() throws {
        let parsed = try #require(ConnectionURL.parse("postgres://me:p@ss@host/db"))
        #expect(parsed.user == "me")
        #expect(parsed.password == "p@ss")
        #expect(parsed.host == "host")
    }

    @Test func jdbcPrefixAndSurroundingQuotesAreStripped() throws {
        let parsed = try #require(
            ConnectionURL.parse("  \"jdbc:postgresql://host:5432/app\"  "))
        #expect(parsed.driverID == "postgres")
        #expect(parsed.host == "host")
        #expect(parsed.port == 5432)
        #expect(parsed.database == "app")
    }

    @Test func mongoSeedListStaysWholeAndSRVImpliesTLS() throws {
        let parsed = try #require(
            ConnectionURL.parse("mongodb://a:1@h1:27017,h2:27017/admin?authSource=admin"))
        #expect(parsed.driverID == "mongodb")
        #expect(parsed.host == "h1:27017,h2:27017")
        #expect(parsed.port == nil)
        #expect(parsed.database == "admin")

        let srv = try #require(ConnectionURL.parse("mongodb+srv://u:p@cluster.mongodb.net/app"))
        #expect(srv.driverID == "mongodb")
        #expect(srv.host == "cluster.mongodb.net")
        #expect(srv.tls == .required)
    }

    @Test func redissImpliesTLSAndPathIsTheDatabaseIndex() throws {
        let parsed = try #require(ConnectionURL.parse("rediss://:token@cache.example.com:6380/2"))
        #expect(parsed.driverID == "redis")
        #expect(parsed.user == nil)
        #expect(parsed.password == "token")
        #expect(parsed.port == 6380)
        #expect(parsed.database == "2")
        #expect(parsed.tls == .required)
    }

    @Test func ipv6LiteralLosesItsBrackets() throws {
        let parsed = try #require(ConnectionURL.parse("postgres://[::1]:5432/app"))
        #expect(parsed.host == "::1")
        #expect(parsed.port == 5432)
        #expect(parsed.database == "app")
    }

    @Test func sqliteFormsBecomeAFilePath() throws {
        let absolute = try #require(ConnectionURL.parse("sqlite:///Users/me/app.sqlite"))
        #expect(absolute.driverID == "sqlite")
        #expect(absolute.filePath == "/Users/me/app.sqlite")
        #expect(absolute.host == nil)

        let schemeOnly = try #require(ConnectionURL.parse("sqlite:~/app.sqlite"))
        #expect(schemeOnly.driverID == "sqlite")
        #expect(schemeOnly.filePath == "~/app.sqlite")

        let file = try #require(ConnectionURL.parse("file:///tmp/db%20one.sqlite"))
        #expect(file.filePath == "/tmp/db one.sqlite")
    }

    @Test func metabaseKeepsTheWholeInstanceURLAsHost() throws {
        let parsed = try #require(ConnectionURL.parse("https://metabase.example.com:8443/mb"))
        #expect(parsed.driverID == "metabase")
        #expect(parsed.host == "https://metabase.example.com:8443/mb")
        #expect(parsed.port == nil)
        #expect(parsed.database == nil)
    }

    @Test func tlsVocabularies() throws {
        #expect(ConnectionURL.parse("postgres://h/db?sslmode=disable")?.tls == .disabled)
        #expect(ConnectionURL.parse("postgres://h/db?sslmode=verify-full")?.tls == .required)
        #expect(ConnectionURL.parse("postgres://h/db?sslmode=prefer")?.tls == .preferred)
        #expect(ConnectionURL.parse("mysql://h/db?ssl-mode=VERIFY_IDENTITY")?.tls == .required)
        #expect(ConnectionURL.parse("mongodb://h/db?tls=true")?.tls == .required)
        #expect(ConnectionURL.parse("mysql://h/db?useSSL=false")?.tls == .disabled)
        #expect(ConnectionURL.parse("postgres://h/db?sslmode=nonsense")?.tls == nil)
    }

    @Test func queryParametersCanCarryCredentials() throws {
        let parsed = try #require(
            ConnectionURL.parse("postgres://host:5432/?user=me&password=pw&dbname=app"))
        #expect(parsed.user == "me")
        #expect(parsed.password == "pw")
        #expect(parsed.database == "app")
    }

    @Test func libpqKeywordForm() throws {
        let parsed = try #require(
            ConnectionURL.parse("host=db.example.com port=5432 dbname=app user=me sslmode=require"))
        #expect(parsed.driverID == nil)
        #expect(parsed.host == "db.example.com")
        #expect(parsed.port == 5432)
        #expect(parsed.database == "app")
        #expect(parsed.user == "me")
        #expect(parsed.tls == .required)
    }

    @Test func unusableStringsParseToNil() {
        // Half-typed URLs must not blank out the form's fields.
        #expect(ConnectionURL.parse("") == nil)
        #expect(ConnectionURL.parse("postgres://") == nil)
        #expect(ConnectionURL.parse("post") == nil)
        #expect(ConnectionURL.parse("sqlite://") == nil)
        #expect(ConnectionURL.parse("dbname=app") == nil)
    }

    @Test func unknownSchemeStillYieldsFieldsButNoDriver() throws {
        let parsed = try #require(ConnectionURL.parse("clickhouse://me@host:9000/analytics"))
        #expect(parsed.driverID == nil)
        #expect(parsed.host == "host")
        #expect(parsed.port == 9000)
        #expect(parsed.user == "me")
        #expect(parsed.database == "analytics")
    }

    @Test func dynamoDBMapsTheRegionToTheHostField() throws {
        let parsed = try #require(ConnectionURL.parse("dynamodb://key:secret@eu-central-1"))
        #expect(parsed.driverID == "dynamodb")
        #expect(parsed.host == "eu-central-1")
        #expect(parsed.user == "key")
        #expect(parsed.password == "secret")
    }
}
