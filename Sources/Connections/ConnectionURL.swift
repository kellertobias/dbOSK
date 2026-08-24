import DBCore
import Foundation

/// A pasted connection string, split into the discrete fields the connection
/// form (and `ConnectionProfile`) keeps.
///
/// Accepts the URL forms the engines' own tools print — `postgres://`,
/// `mysql://`, `mongodb+srv://`, `rediss://`, `sqlite:///path` — with an
/// optional `jdbc:` prefix, plus libpq's `host=… dbname=…` keyword form.
/// Every component is optional: only what the string actually carries comes
/// back set, so callers can leave the rest of the form alone.
public struct ConnectionURL: Sendable, Equatable {
    /// Matches `DriverDescriptor.id`. Nil when the string names no engine
    /// (the keyword form, which is libpq's but works for any of them).
    public var driverID: String?
    public var host: String?
    public var port: Int?
    public var user: String?
    public var password: String?
    public var database: String?
    /// Set instead of host/port for file-based engines (SQLite).
    public var filePath: String?
    public var tls: ResolvedConnectionConfig.TLSMode?

    public init(
        driverID: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        password: String? = nil,
        database: String? = nil,
        filePath: String? = nil,
        tls: ResolvedConnectionConfig.TLSMode? = nil
    ) {
        self.driverID = driverID
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.filePath = filePath
        self.tls = tls
    }

    /// Parses `text`, or returns nil when it isn't (yet) a usable connection
    /// string — a half-typed URL with no host resolves to nil rather than to
    /// a value that would blank out fields.
    public static func parse(_ text: String) -> ConnectionURL? {
        var text = unquoted(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return nil }
        // `jdbc:postgresql://…` — the wrapper adds nothing we need.
        if text.lowercased().hasPrefix("jdbc:") { text = String(text.dropFirst(5)) }

        if let separator = text.range(of: "://") {
            return parseURL(
                scheme: text[..<separator.lowerBound].lowercased(),
                body: String(text[separator.upperBound...]))
        }
        // Schemeless-authority file forms: `sqlite:/tmp/db.sqlite`, `file:db.sqlite`.
        if let colon = text.firstIndex(of: ":"),
            fileSchemes.contains(text[..<colon].lowercased())
        {
            let path = decoded(String(text[text.index(after: colon)...]))
            return path.isEmpty ? nil : ConnectionURL(driverID: "sqlite", filePath: path)
        }
        return parseKeywords(text)
    }

    // MARK: - Scheme table

    private static let fileSchemes: Set<String> = ["sqlite", "sqlite3", "file"]

    private static let driverIDsByScheme: [String: String] = [
        "postgres": "postgres", "postgresql": "postgres", "psql": "postgres",
        "mysql": "mysql", "mariadb": "mysql",
        "mongodb": "mongodb", "mongodb+srv": "mongodb",
        "redis": "redis", "rediss": "redis", "valkey": "redis",
        "sqlite": "sqlite", "sqlite3": "sqlite", "file": "sqlite",
        "dynamodb": "dynamodb",
        // Metabase is the only HTTP-API driver, so an http(s) URL means it.
        "metabase": "metabase", "http": "metabase", "https": "metabase",
    ]

    /// Schemes that are the TLS variant of their plain sibling.
    private static let tlsSchemes: Set<String> = ["rediss", "mongodb+srv", "https"]

    // MARK: - URL form

    private static func parseURL(scheme: String, body: String) -> ConnectionURL? {
        var result = ConnectionURL(driverID: driverIDsByScheme[scheme])

        var body = body
        var query = ""
        if let mark = body.firstIndex(of: "?") {
            query = String(body[body.index(after: mark)...])
            body = String(body[..<mark])
        }
        if let hash = body.firstIndex(of: "#") { body = String(body[..<hash]) }

        // A file URL is all path — there is no authority to split off.
        if result.driverID == "sqlite" {
            let path = decoded(body)
            guard !path.isEmpty else { return nil }
            result.filePath = path
            return result
        }

        var authority = body
        var path = ""
        if let slash = body.firstIndex(of: "/") {
            authority = String(body[..<slash])
            path = String(body[body.index(after: slash)...])
        }

        // Last "@", so an unescaped "@" inside the password still parses.
        if let at = authority.lastIndex(of: "@") {
            let userInfo = String(authority[..<at])
            authority = String(authority[authority.index(after: at)...])
            if let colon = userInfo.firstIndex(of: ":") {
                result.user = nonEmpty(decoded(String(userInfo[..<colon])))
                result.password = nonEmpty(
                    decoded(String(userInfo[userInfo.index(after: colon)...])))
            } else {
                result.user = nonEmpty(decoded(userInfo))
            }
        }

        if authority.contains(",") {
            // A replica-set seed list — every host matters, so keep it whole.
            result.host = nonEmpty(decoded(authority))
        } else if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            // Bracketed IPv6 literal; the drivers want the bare address.
            result.host = nonEmpty(
                String(authority[authority.index(after: authority.startIndex)..<close]))
            let trailer = authority[authority.index(after: close)...]
            if trailer.hasPrefix(":") { result.port = Int(trailer.dropFirst()) }
        } else if let colon = authority.lastIndex(of: ":"),
            let port = Int(authority[authority.index(after: colon)...])
        {
            result.host = nonEmpty(decoded(String(authority[..<colon])))
            result.port = port
        } else {
            result.host = nonEmpty(decoded(authority))
        }

        // Postgres/MySQL/Mongo all name the database in the first path
        // segment; Redis names the numeric database index there.
        if let segment = path.split(separator: "/", maxSplits: 1).first {
            result.database = nonEmpty(decoded(String(segment)))
        }

        if tlsSchemes.contains(scheme) { result.tls = .required }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let key = decoded(String(parts[0])).lowercased()
            let value = parts.count > 1 ? decoded(String(parts[1])) : ""
            apply(key: key, value: value, to: &result)
        }

        guard result.host != nil else { return nil }
        if result.driverID == "metabase" {
            // The Metabase field holds the whole instance URL, not a bare host.
            let scheme = scheme == "http" ? "http" : "https"
            let port = result.port.map { ":\($0)" } ?? ""
            let path = path.isEmpty ? "" : "/\(path)"
            result.host = "\(scheme)://\(result.host ?? "")\(port)\(path)"
            result.port = nil
            result.database = nil
            result.tls = nil
        }
        return result
    }

    /// Query parameters, which can carry credentials and TLS settings the
    /// authority doesn't.
    private static func apply(key: String, value: String, to result: inout ConnectionURL) {
        switch key {
        case "user", "username", "uid":
            result.user = nonEmpty(value) ?? result.user
        case "password", "pwd":
            result.password = nonEmpty(value) ?? result.password
        case "database", "dbname", "db":
            result.database = nonEmpty(value) ?? result.database
        case "port":
            result.port = Int(value) ?? result.port
        case "host":
            result.host = nonEmpty(value) ?? result.host
        case "sslmode", "ssl-mode", "ssl_mode", "ssl", "tls", "usessl", "use-ssl":
            result.tls = tlsMode(value) ?? result.tls
        default:
            break
        }
    }

    /// Maps both libpq's `sslmode=` vocabulary and the boolean `ssl=`/`tls=`
    /// flags the other drivers use.
    private static func tlsMode(_ value: String) -> ResolvedConnectionConfig.TLSMode? {
        switch value.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "disable", "disabled", "off", "false", "0", "no":
            return .disabled
        case "allow", "prefer", "preferred":
            return .preferred
        case "require", "required", "verify-ca", "verify-full", "verify-identity",
            "on", "true", "1", "yes":
            return .required
        default:
            return nil
        }
    }

    // MARK: - Keyword form

    /// libpq's `host=localhost port=5432 dbname=app user=me` string, which
    /// names no engine — the caller keeps whichever driver is selected.
    private static func parseKeywords(_ text: String) -> ConnectionURL? {
        var result = ConnectionURL()
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let equals = token.firstIndex(of: "=") else { continue }
            let key = token[..<equals].lowercased()
            let value = unquoted(String(token[token.index(after: equals)...]))
            switch key {
            case "hostaddr" where result.host == nil:
                result.host = nonEmpty(value)
            default:
                apply(key: key, value: value, to: &result)
            }
        }
        guard result.host != nil else { return nil }
        return result
    }

    // MARK: - Helpers

    private static func decoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    /// Strips the quotes a copy from a shell command line brings along.
    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
            first == last, first == "\"" || first == "'"
        else { return text }
        return String(text.dropFirst().dropLast())
    }
}
