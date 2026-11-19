import Testing
import Foundation
@testable import CadenceServer

private let key = TestLibrary.key

/// Two tools: one that answers, one that fails in each way a tool can.
private struct StubTools: MCPToolHandler {
    struct Leaky: Error, CustomStringConvertible {
        var description: String { "/Users/someone/Music/library.sqlite: disk I/O error" }
    }

    var tools: [MCPTool] {
        [MCPTool(name: "echo", description: "Says back what it was given.",
                 inputSchema: ["type": "object",
                               "properties": ["text": ["type": "string"]],
                               "required": ["text"]],
                 annotations: .readOnly),
         MCPTool(name: "fail", description: "Fails.",
                 annotations: .init(destructive: true))]
    }

    func call(_ name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        switch name {
        case "echo":
            guard let text = arguments["text"]?.stringValue else {
                throw MCPToolError("echo needs text.")
            }
            return MCPToolResult(text: text, structured: ["text": .string(text)])
        default:
            throw Leaky()
        }
    }
}

private func makeServer(failureLimit: Int = 10, now: @escaping @Sendable () -> Date = Date.init)
    -> MCPServer {
    var configuration = MCPServer.Configuration(serverVersion: "9.8.7",
                                                instructions: "Be kind to the library.")
    configuration.failureLimit = failureLimit
    configuration.now = now
    return MCPServer(configuration: configuration,
                     authenticator: FixedKeyAuthenticator(key: key), tools: StubTools())
}

private func post(_ server: MCPServer, _ body: String, key: String? = key,
                  headers: [String: String] = [:], path: String = "/mcp",
                  method: HTTPRequest.Method = .post) async -> HTTPResponse {
    var all = ["content-type": "application/json",
               "accept": "application/json, text/event-stream"]
    if let key { all["authorization"] = "Bearer \(key)" }
    all.merge(headers) { _, new in new }
    return await server.respond(to: HTTPRequest(
        method: method, path: path, headers: all, body: Data(body.utf8),
        remoteAddress: "127.0.0.1"))
}

private func json(_ response: HTTPResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

private func rpc(_ method: String, id: Int = 1, params: String = "{}") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
}

@Suite("MCP server")
struct MCPServerTests {

    // MARK: Lifecycle

    @Test("initialize agrees on a version the client asked for and lists tools as a capability")
    func initialize() async throws {
        let response = await post(makeServer(), rpc(
            "initialize", params: #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}"#))
        #expect(response.status == .ok)
        #expect(response.contentType == "application/json")
        let body = try json(response)
        #expect(body["jsonrpc"] as? String == "2.0")
        #expect(body["id"] as? Int == 1)
        let result = try #require(body["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect(result["instructions"] as? String == "Be kind to the library.")
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "cadence")
        #expect(info["version"] as? String == "9.8.7")
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil)
    }

    @Test("initialize with an unknown version is offered the newest")
    func initializeUnknownVersion() async throws {
        let response = await post(makeServer(), rpc(
            "initialize", params: #"{"protocolVersion":"1999-01-01"}"#))
        let result = try #require(try json(response)["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPServer.supportedProtocolVersions[0])
    }

    @Test("Notifications and client responses are accepted with no body")
    func notifications() async {
        let server = makeServer()
        let initialized = await post(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(initialized.status == .accepted)
        #expect(initialized.body.isEmpty)
        let response = await post(server, #"{"jsonrpc":"2.0","id":7,"result":{}}"#)
        #expect(response.status == .accepted)
    }

    @Test("ping answers an empty result, and a string id comes back as sent")
    func ping() async throws {
        let response = await post(makeServer(), #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
        let body = try json(response)
        #expect(body["id"] as? String == "abc")
        #expect((body["result"] as? [String: Any])?.isEmpty == true)
    }

    // MARK: Tools

    @Test("tools/list describes each tool with its schema and hints")
    func listTools() async throws {
        let response = await post(makeServer(), rpc("tools/list"))
        let result = try #require(try json(response)["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["echo", "fail"])
        let echo = tools[0]
        #expect((echo["inputSchema"] as? [String: Any])?["required"] as? [String] == ["text"])
        let hints = try #require(echo["annotations"] as? [String: Any])
        #expect(hints["readOnlyHint"] as? Bool == true)
        #expect(hints["destructiveHint"] as? Bool == false)
        #expect((tools[1]["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == true)
    }

    @Test("tools/call returns text and structured content")
    func callTool() async throws {
        let response = await post(makeServer(), rpc(
            "tools/call", params: #"{"name":"echo","arguments":{"text":"hello"}}"#))
        let result = try #require(try json(response)["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == "hello")
        #expect((result["structuredContent"] as? [String: Any])?["text"] as? String == "hello")
    }

    @Test("A tool's own error reaches the model as a result, not a protocol error")
    func toolError() async throws {
        let response = await post(makeServer(), rpc(
            "tools/call", params: #"{"name":"echo","arguments":{}}"#))
        let body = try json(response)
        #expect(body["error"] == nil)
        let result = try #require(body["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect((result["content"] as? [[String: Any]])?.first?["text"] as? String == "echo needs text.")
    }

    @Test("Any other error is reported without its description")
    func leakyError() async throws {
        let response = await post(makeServer(), rpc("tools/call", params: #"{"name":"fail"}"#))
        let text = String(decoding: response.body, as: UTF8.self)
        #expect(!text.contains("/Users"))
        #expect(!text.contains("sqlite"))
        let result = try #require(try json(response)["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test("An unknown tool or bad arguments are invalid params")
    func unknownTool() async throws {
        for params in [#"{"name":"nope"}"#, #"{}"#, #"{"name":"echo","arguments":[1]}"#] {
            let response = await post(makeServer(), rpc("tools/call", params: params))
            let error = try #require(try json(response)["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32602)
        }
    }

    // MARK: JSON-RPC

    @Test("An unknown method is method-not-found, with the id")
    func unknownMethod() async throws {
        let response = await post(makeServer(), rpc("resources/list", id: 4))
        let body = try json(response)
        #expect(body["id"] as? Int == 4)
        #expect((body["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test("Malformed messages are 400 with a JSON-RPC error and a null id",
          arguments: [
            ("{not json", -32700),
            (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, -32600),
            (#""ping""#, -32600),
            (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, -32600),
            (#"{"jsonrpc":"2.0","id":1}"#, -32600),
            (#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, -32600),
            (#"{"jsonrpc":"2.0","id":{},"method":"ping"}"#, -32600),
            (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[1]}"#, -32600),
          ])
    func malformed(body: String, code: Int) async throws {
        let response = await post(makeServer(), body)
        #expect(response.status == .badRequest)
        let decoded = try json(response)
        #expect(decoded["id"] is NSNull)
        #expect((decoded["error"] as? [String: Any])?["code"] as? Int == code)
    }

    // MARK: HTTP

    @Test("Only /mcp answers")
    func otherPaths() async {
        for path in ["/", "/rest/ping", "/mcp/", "/MCP", "/pair"] {
            #expect(await post(makeServer(), rpc("ping"), path: path).status == .notFound)
        }
    }

    @Test("GET is refused with Allow: POST, so a client knows there is no stream")
    func getRefused() async {
        let response = await post(makeServer(), "", method: .get)
        #expect(response.status == .methodNotAllowed)
        #expect(response.headers.contains { $0.name == "Allow" && $0.value == "POST" })
    }

    @Test("A body that is not JSON by content type is refused")
    func contentType() async {
        let response = await post(makeServer(), rpc("ping"),
                                  headers: ["content-type": "text/plain"])
        #expect(response.status == .unsupportedMediaType)
        let withCharset = await post(makeServer(), rpc("ping"),
                                     headers: ["content-type": "application/json; charset=utf-8"])
        #expect(withCharset.status == .ok)
    }

    @Test("An unsupported MCP-Protocol-Version header is 400; a supported one is fine")
    func protocolVersionHeader() async {
        let bad = await post(makeServer(), rpc("ping"), headers: ["mcp-protocol-version": "2020-01-01"])
        #expect(bad.status == .badRequest)
        let good = await post(makeServer(), rpc("ping"), headers: ["mcp-protocol-version": "2025-06-18"])
        #expect(good.status == .ok)
    }

    // MARK: Authorization

    @Test("No key, a wrong key and a wrong scheme all get the same 401")
    func unauthorized() async {
        let server = makeServer()
        let responses = [
            await post(server, rpc("ping"), key: nil),
            await post(server, rpc("ping"), key: "wrong"),
            await post(server, rpc("ping"), key: ""),
            await post(server, rpc("ping"), key: nil, headers: ["authorization": "Basic \(key)"]),
            await post(server, rpc("ping"), key: nil, headers: ["authorization": key]),
        ]
        for response in responses {
            #expect(response.status == .unauthorized)
            #expect(response.body.isEmpty)
            #expect(response.headers.contains { $0.name == "WWW-Authenticate" && $0.value == "Bearer" })
        }
    }

    @Test("The scheme is case-insensitive")
    func schemeCase() async {
        let response = await post(makeServer(), rpc("ping"), key: nil,
                                  headers: ["authorization": "bearer \(key)"])
        #expect(response.status == .ok)
    }

    @Test("Repeated failures block the address, the right key included")
    func throttle() async {
        let server = makeServer(failureLimit: 3)
        for _ in 0..<3 { _ = await post(server, rpc("ping"), key: "wrong") }
        let blocked = await post(server, rpc("ping"))
        #expect(blocked.status == .tooManyRequests)
        #expect(blocked.headers.contains { $0.name == "Retry-After" })
    }

    // MARK: Origin

    @Test("A request from a web page elsewhere is refused before the key is checked",
          arguments: ["https://evil.example", "http://localhost.evil.example",
                      "null", "file://", "http://192.168.1.10:8080"])
    func foreignOrigin(origin: String) async {
        let response = await post(makeServer(), rpc("ping"), headers: ["origin": origin])
        #expect(response.status == .forbidden)
    }

    @Test("A local origin is allowed", arguments: [
        "http://localhost:6274", "http://127.0.0.1", "https://localhost", "http://[::1]:3000",
    ])
    func localOrigin(origin: String) async {
        let response = await post(makeServer(), rpc("ping"), headers: ["origin": origin])
        #expect(response.status == .ok)
    }
}

/// The endpoint over a real socket, through the listener a release build uses.
@Suite("MCP listener", .serialized)
struct MCPListenerTests {

    @Test("A tool call round-trips over loopback, with a body past the pairing limit")
    func roundTrip() async throws {
        let listener = try HTTPListener.mcp(server: makeServer(), port: nil)
        let port = try await listener.start()
        defer { listener.stop() }

        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // Past the 1 KB the library server's pairing route allows.
        let long = String(repeating: "a", count: 4096)
        request.httpBody = Data(rpc("tools/call",
                                    params: #"{"name":"echo","arguments":{"text":"\#(long)"}}"#).utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(body["result"] as? [String: Any])
        #expect((result["structuredContent"] as? [String: Any])?["text"] as? String == long)
    }
}
