import Connections
import DBCore
import Foundation
import Testing

@testable import MCPServer

/// Full-stack tests: real HTTP over loopback → transport → MCP server →
/// tools → fake driver.
@Suite struct MCPServerEndToEndTests {

    private func post(
        _ body: [String: Any], port: Int, token: String? = nil
    ) async throws -> (status: Int, json: [String: Any]?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (status, json)
    }

    private func initializeBody(id: Int = 1) -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "test", "version": "1.0"],
            ],
        ]
    }

    private func callBody(
        id: Int, tool: String, arguments: [String: Any]
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
    }

    /// Extracts the text payload of a tool result and whether it was an error.
    private func toolResult(_ json: [String: Any]?) -> (text: String, isError: Bool) {
        let result = json?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        let isError = result?["isError"] as? Bool ?? false
        return (text, isError)
    }

    @Test func fullFlowOverHTTP() async throws {
        let connection = exposed()
        let server = DboskMCPServer(provider: StubProvider(items: [connection]))
        let port = try await server.start(port: 0, token: "sekrit")
        defer { Task { await server.stop() } }

        // Without token: 401.
        let unauthorized = try await post(initializeBody(), port: port)
        #expect(unauthorized.status == 401)

        // initialize
        let initResponse = try await post(initializeBody(), port: port, token: "sekrit")
        #expect(initResponse.status == 200)
        let serverInfo = (initResponse.json?["result"] as? [String: Any])?["serverInfo"]
            as? [String: Any]
        #expect(serverInfo?["name"] as? String == "dbosk")

        // notifications/initialized → 202
        let notified = try await post(
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            port: port, token: "sekrit")
        #expect(notified.status == 202)

        // tools/list
        let toolsResponse = try await post(
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            port: port, token: "sekrit")
        let tools = (toolsResponse.json?["result"] as? [String: Any])?["tools"]
            as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == [
            "list_connections", "list_namespaces", "describe_table",
            "query", "mongo_query", "explain_query",
        ])

        // list_connections
        let listResponse = try await post(
            callBody(id: 3, tool: "list_connections", arguments: [:]),
            port: port, token: "sekrit")
        let list = toolResult(listResponse.json)
        #expect(!list.isError)
        #expect(list.text.contains(connection.id))

        // query (SELECT) succeeds
        let queryResponse = try await post(
            callBody(id: 4, tool: "query", arguments: [
                "connection_id": connection.id, "sql": "SELECT 1",
            ]),
            port: port, token: "sekrit")
        let query = toolResult(queryResponse.json)
        #expect(!query.isError)
        #expect(query.text.contains("\"row_count\":2"))

        // DELETE is refused by the gate
        let deleteResponse = try await post(
            callBody(id: 5, tool: "query", arguments: [
                "connection_id": connection.id, "sql": "DELETE FROM users",
            ]),
            port: port, token: "sekrit")
        let delete = toolResult(deleteResponse.json)
        #expect(delete.isError)
        #expect(delete.text.contains("read-only"))

        // CTE write smuggling is refused
        let cteResponse = try await post(
            callBody(id: 6, tool: "query", arguments: [
                "connection_id": connection.id,
                "sql": "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d",
            ]),
            port: port, token: "sekrit")
        #expect(toolResult(cteResponse.json).isError)

        await server.stop()
    }

    @Test func authDisabledAllowsRequests() async throws {
        let server = DboskMCPServer(provider: StubProvider(items: [exposed()]))
        let port = try await server.start(port: 0, token: nil)
        let response = try await post(initializeBody(), port: port)
        #expect(response.status == 200)
        await server.stop()
    }

    @Test func nonPostAndWrongPathRejected() async throws {
        let server = DboskMCPServer(provider: StubProvider(items: []))
        let port = try await server.start(port: 0, token: nil)

        var get = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        get.httpMethod = "GET"
        let (_, getResponse) = try await URLSession.shared.data(for: get)
        #expect((getResponse as! HTTPURLResponse).statusCode == 405)

        var wrongPath = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/other")!)
        wrongPath.httpMethod = "POST"
        let (_, pathResponse) = try await URLSession.shared.data(for: wrongPath)
        #expect((pathResponse as! HTTPURLResponse).statusCode == 404)

        await server.stop()
    }

    @Test func connectionGatingErrors() async throws {
        let disabled = exposed(access: MCPAccessConfig(enabled: false))
        let server = DboskMCPServer(provider: StubProvider(items: [disabled]))
        let port = try await server.start(port: 0, token: nil)

        // Disabled connections are invisible in list_connections…
        let listResponse = try await post(
            callBody(id: 1, tool: "list_connections", arguments: [:]), port: port)
        #expect(!toolResult(listResponse.json).text.contains(disabled.id))

        // …and addressing one directly explains how to enable it.
        let queryResponse = try await post(
            callBody(id: 2, tool: "query", arguments: [
                "connection_id": disabled.id, "sql": "SELECT 1",
            ]),
            port: port)
        let result = toolResult(queryResponse.json)
        #expect(result.isError)
        #expect(result.text.contains("not enabled for MCP"))

        // Unknown id gets a pointer to list_connections.
        let unknownResponse = try await post(
            callBody(id: 3, tool: "query", arguments: [
                "connection_id": "nope", "sql": "SELECT 1",
            ]),
            port: port)
        #expect(toolResult(unknownResponse.json).text.contains("list_connections"))

        await server.stop()
    }

    @Test func allowlistEnforcement() async throws {
        let restricted = exposed(
            access: MCPAccessConfig(
                enabled: true, scope: .allowlist([["public", "users"]])))
        let server = DboskMCPServer(provider: StubProvider(items: [restricted]))
        let port = try await server.start(port: 0, token: nil)

        // Allowed table (qualified and unqualified tail match).
        for sql in ["SELECT * FROM public.users", "SELECT * FROM users"] {
            let response = try await post(
                callBody(id: 1, tool: "query", arguments: [
                    "connection_id": restricted.id, "sql": sql,
                ]),
                port: port)
            #expect(!toolResult(response.json).isError, "expected allow: \(sql)")
        }

        // Disallowed tables: direct, via JOIN, via CTE.
        for sql in [
            "SELECT * FROM public.orders",
            "SELECT * FROM users u JOIN orders o ON u.id = o.user_id",
            "WITH x AS (SELECT * FROM secret_table) SELECT * FROM x",
        ] {
            let response = try await post(
                callBody(id: 2, tool: "query", arguments: [
                    "connection_id": restricted.id, "sql": sql,
                ]),
                port: port)
            let result = toolResult(response.json)
            #expect(result.isError, "expected reject: \(sql)")
            #expect(result.text.contains("allowlist"))
        }

        // list_namespaces filters to allowed scope.
        let namespaces = try await post(
            callBody(id: 3, tool: "list_namespaces", arguments: [
                "connection_id": restricted.id,
            ]),
            port: port)
        let text = toolResult(namespaces.json).text
        #expect(text.contains("public"))
        #expect(!text.contains("private"))

        // describe_table on a non-allowed table is refused.
        let describe = try await post(
            callBody(id: 4, tool: "describe_table", arguments: [
                "connection_id": restricted.id, "path": ["public", "orders"],
            ]),
            port: port)
        #expect(toolResult(describe.json).isError)

        await server.stop()
    }

    @Test func batchRequestsRejected() async throws {
        let server = DboskMCPServer(provider: StubProvider(items: []))
        let port = try await server.start(port: 0, token: nil)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [initializeBody()])
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 400)
        await server.stop()
    }
}
