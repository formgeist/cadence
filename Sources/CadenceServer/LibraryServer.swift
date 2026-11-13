import Foundation

/// The read-only library server: takes a parsed request, returns a response.
///
/// It knows nothing about sockets. `HTTPListener` feeds it requests in the
/// app; tests call `respond(to:)` directly. That split is what lets every
/// endpoint be tested without opening a port.
///
/// **There is no write path.** The only methods a request can arrive with are
/// `GET` and `HEAD`, no endpoint in the table changes anything, and a request
/// body is refused by the parser before it reaches here.
public struct LibraryServer: Sendable {

    public struct Configuration: Sendable {
        /// Reported to clients in every response, so a client can tell which
        /// release it is talking to.
        public var serverVersion: String

        public init(serverVersion: String) {
            self.serverVersion = serverVersion
        }
    }

    private let configuration: Configuration
    private let authenticator: any Authenticator

    public init(configuration: Configuration, authenticator: any Authenticator) {
        self.configuration = configuration
        self.authenticator = authenticator
    }

    // MARK: - Routing

    private enum Endpoint: String, CaseIterable {
        case ping
        case getOpenSubsonicExtensions

        /// The one endpoint a client may call before it has a key: it is how
        /// a client learns which ways of signing in the server offers.
        var isPublic: Bool { self == .getOpenSubsonicExtensions }
    }

    public func respond(to request: HTTPRequest) async -> HTTPResponse {
        // `/rest/<name>`, or `/rest/<name>.view` as older clients spell it.
        // An exact match against the table: the path is never interpreted.
        guard request.path.hasPrefix("/rest/") else { return .empty(.notFound) }
        var name = String(request.path.dropFirst("/rest/".count))
        if name.hasSuffix(".view") { name.removeLast(".view".count) }
        guard let endpoint = Endpoint(rawValue: name) else {
            return failure(.generic, "Unknown endpoint.", status: .notFound)
        }

        if !endpoint.isPublic, let refusal = await authenticate(request) {
            return refusal
        }

        switch endpoint {
        case .ping:
            return SubsonicResponse.ok(serverVersion: configuration.serverVersion).httpResponse()
        case .getOpenSubsonicExtensions:
            return SubsonicResponse.ok(
                "openSubsonicExtensions",
                [Extension(name: "apiKeyAuthentication", versions: [1])],
                serverVersion: configuration.serverVersion).httpResponse()
        }
    }

    // MARK: - Authentication

    /// Nil when the request carries a valid API key; otherwise the refusal.
    ///
    /// API keys are the only way in. A user name, password or token is
    /// refused as a mechanism, not checked, so there is no password for
    /// anyone to guess. A missing key and a wrong key get the same answer.
    private func authenticate(_ request: HTTPRequest) async -> HTTPResponse? {
        let legacy = ["u", "p", "t", "s"].contains { request.parameter($0) != nil }
        guard let key = request.parameter("apiKey") else {
            return legacy
                ? failure(.authenticationMechanismNotSupported,
                          "This server accepts API keys only.")
                : failure(.invalidAPIKey, "Invalid API key.")
        }
        guard !legacy else {
            return failure(.conflictingAuthentication,
                           "Send an API key alone, without a user name.")
        }
        guard await authenticator.isValid(apiKey: key) else {
            return failure(.invalidAPIKey, "Invalid API key.")
        }
        return nil
    }

    private func failure(
        _ code: SubsonicResponse.ErrorCode, _ message: String, status: HTTPStatus = .ok
    ) -> HTTPResponse {
        SubsonicResponse.failed(.init(code, message), serverVersion: configuration.serverVersion)
            .httpResponse(status: status)
    }

    private struct Extension: Encodable, Sendable {
        var name: String
        var versions: [Int]
    }
}
