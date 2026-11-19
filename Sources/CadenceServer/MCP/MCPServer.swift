import Foundation

/// The MCP endpoint agents talk to: takes a parsed request, returns a
/// response. Like `LibraryServer` it knows nothing about sockets, so every
/// rule here is tested without opening a port.
///
/// **This server can change the library**, which `LibraryServer` never does.
/// That is why it is a server of its own, on a listener of its own, and never
/// a route on the one paired devices reach:
///
/// - It is served on the loopback interface only (`HTTPListener.localOnly`).
///   Nothing off this Mac can connect.
/// - It takes one key, as `Authorization: Bearer`, separate from any paired
///   device's key.
/// - It refuses any request whose `Origin` is not this machine, so a web page
///   open in a browser cannot reach it through the user's own loopback
///   (DNS rebinding).
///
/// The transport is MCP's Streamable HTTP, answering every request with one
/// JSON body: `POST /mcp` only, no event stream, no sessions. A `GET`, which a
/// client sends to open a stream, is answered 405, which the transport allows.
public struct MCPServer: Sendable {

    public struct Configuration: Sendable {
        public var serverName = "cadence"
        public var serverVersion: String
        /// Sent in `initialize`, for the client to put in front of the model.
        public var instructions: String?
        /// As `LibraryServer.Configuration`: failed attempts from one address
        /// within `failureWindow` before it is refused for `blockDuration`.
        public var failureLimit = 10
        public var failureWindow: TimeInterval = 60
        public var blockDuration: TimeInterval = 60
        public var now: @Sendable () -> Date = Date.init

        public init(serverVersion: String, instructions: String? = nil) {
            self.serverVersion = serverVersion
            self.instructions = instructions
        }
    }

    /// Newest first. A client asking for one of these gets it; a client
    /// asking for anything else is offered the first, and decides.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    /// The path the endpoint answers on.
    public static let path = "/mcp"

    /// Listener limits sized for MCP. The default body limit is the pairing
    /// route's 1 KB; a tool call with a few hundred track ids needs more.
    public static var listenerLimits: HTTPListener.Limits {
        var limits = HTTPListener.Limits()
        limits.parser.bodyBytes = 256 * 1024
        return limits
    }

    private let configuration: Configuration
    private let authenticator: any Authenticator
    private let tools: any MCPToolHandler
    private let throttle: FailureThrottle

    public init(configuration: Configuration, authenticator: any Authenticator,
                tools: any MCPToolHandler) {
        self.configuration = configuration
        self.authenticator = authenticator
        self.tools = tools
        throttle = FailureThrottle(
            limit: configuration.failureLimit, window: configuration.failureWindow,
            block: configuration.blockDuration, now: configuration.now)
    }

    // MARK: - HTTP

    public func respond(to request: HTTPRequest) async -> HTTPResponse {
        if let address = request.remoteAddress,
           let seconds = throttle.secondsBlocked(address) {
            return HTTPResponse(
                status: .tooManyRequests,
                headers: [(name: "Retry-After", value: String(max(1, Int(seconds.rounded(.up)))))])
        }
        guard request.path == Self.path else { return .empty(.notFound) }
        // Before the key: a page in a browser must learn nothing, not even
        // whether its guess was right.
        guard Self.isLocalOrigin(request.headers["origin"]) else { return .empty(.forbidden) }
        guard request.method == .post else {
            return HTTPResponse(status: .methodNotAllowed, headers: [(name: "Allow", value: "POST")])
        }
        guard await isAuthorized(request) else {
            if let address = request.remoteAddress { throttle.recordFailure(address) }
            return HTTPResponse(status: .unauthorized,
                                headers: [(name: "WWW-Authenticate", value: "Bearer")])
        }

        let contentType = request.headers["content-type"]?
            .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard contentType == "application/json" else { return .empty(.unsupportedMediaType) }
        // Sent on every request after `initialize`. Absent, the client is
        // either initialising or older than the header; either is fine.
        if let version = request.headers["mcp-protocol-version"],
           !Self.supportedProtocolVersions.contains(version) {
            return Self.json(.badRequest, JSONRPC.error(
                id: nil, .invalidRequest("Unsupported MCP-Protocol-Version.")))
        }

        switch JSONRPC.parse(request.body) {
        case .failure(let error):
            return Self.json(.badRequest, JSONRPC.error(id: nil, error))
        case .success(.response), .success(.notification):
            // `notifications/initialized` and `notifications/cancelled` need
            // nothing from a server that holds no state and runs each call to
            // completion.
            return .empty(.accepted)
        case .success(.request(let id, let method, let params)):
            switch await handle(method, params) {
            case .success(let result):
                return Self.json(.ok, JSONRPC.result(id: id, result))
            case .failure(let error):
                return Self.json(.ok, JSONRPC.error(id: id, error))
            }
        }
    }

    // MARK: - Methods

    private func handle(_ method: String, _ params: [String: JSONValue])
        async -> Result<JSONValue, JSONRPC.ErrorObject> {
        switch method {
        case "initialize":
            return .success(initialize(params))
        case "ping":
            return .success([:])
        case "tools/list":
            // One page: the list is short and fixed.
            return .success(["tools": .array(tools.tools.map(\.json))])
        case "tools/call":
            return await call(params)
        default:
            return .failure(.methodNotFound(method))
        }
    }

    private func initialize(_ params: [String: JSONValue]) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        var result: [String: JSONValue] = [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(configuration.serverName),
                           "version": .string(configuration.serverVersion)],
        ]
        if let instructions = configuration.instructions {
            result["instructions"] = .string(instructions)
        }
        return .object(result)
    }

    private func call(_ params: [String: JSONValue]) async -> Result<JSONValue, JSONRPC.ErrorObject> {
        guard let name = params["name"]?.stringValue else {
            return .failure(.invalidParams("tools/call needs a tool name."))
        }
        guard tools.tools.contains(where: { $0.name == name }) else {
            return .failure(.invalidParams("Unknown tool: \(name.prefix(64))"))
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let value)?: arguments = value
        default: return .failure(.invalidParams("Arguments must be an object."))
        }

        do {
            return .success(try await tools.call(name, arguments: arguments).json)
        } catch let error as MCPToolError {
            return .success(MCPToolResult.failure(error.message).json)
        } catch {
            // Whatever the store said stays here, as in `LibraryServer`: an
            // error's description can hold a path or a query.
            return .success(MCPToolResult.failure("The tool failed.").json)
        }
    }

    // MARK: - Checks

    private func isAuthorized(_ request: HTTPRequest) async -> Bool {
        guard let header = request.headers["authorization"] else { return false }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let key = parts[1].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return false }
        return await authenticator.device(forAPIKey: key) != nil
    }

    /// No `Origin` is a client that is not a browser, which is what an agent
    /// is. One that is present must name this machine.
    static func isLocalOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard let components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    }

    private static func json(_ status: HTTPStatus, _ value: JSONValue) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return HTTPResponse(status: status, contentType: "application/json",
                            body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }
}
