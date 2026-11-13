import Foundation
import CadenceLibrary

/// The read-only library server: takes a parsed request, returns a response.
///
/// It knows nothing about sockets. `HTTPListener` feeds it requests in the
/// app; tests call `respond(to:)` directly. That split is what lets every
/// endpoint be tested without opening a port.
///
/// **The library has no write path.** Everything under `/rest/` is reached
/// with `GET` or `HEAD` only, and no endpoint in the table changes anything.
/// The one request that does change something is `POST /pair`, which can add
/// a paired device and nothing else.
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
    private let endpoints: LibraryEndpoints
    private let pairing: PairingSession?

    /// The server reads `library` and never writes to it: it calls no method
    /// of the store that changes anything.
    public init(configuration: Configuration, authenticator: any Authenticator,
                library: SQLiteLibraryStore, artwork: DiskArtworkStore? = nil,
                pairing: PairingSession? = nil) {
        self.configuration = configuration
        self.authenticator = authenticator
        self.pairing = pairing
        endpoints = LibraryEndpoints(library: library, artwork: artwork)
    }

    // MARK: - Routing

    private enum Endpoint: String, CaseIterable {
        case ping
        case getOpenSubsonicExtensions
        case getMusicFolders
        case getArtists
        case getArtist
        case getAlbum
        case getAlbumList2
        case getSong
        case search3
        case stream
        case download
        case getCoverArt
        case getPlaylists
        case getPlaylist
        case getStarred2

        /// The one endpoint a client may call before it has a key: it is how
        /// a client learns which ways of signing in the server offers.
        var isPublic: Bool { self == .getOpenSubsonicExtensions }
    }

    public func respond(to request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/pair" { return await pair(request) }
        // Everything else is the library, which is read with `GET` and
        // `HEAD` and nothing more.
        guard request.method != .post else { return .empty(.methodNotAllowed) }

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

        do {
            switch endpoint {
            case .ping:
                return SubsonicResponse.ok(serverVersion: configuration.serverVersion)
                    .httpResponse()
            case .getOpenSubsonicExtensions:
                return ok("openSubsonicExtensions",
                          [Extension(name: "apiKeyAuthentication", versions: [1])])
            case .getMusicFolders:
                return ok("musicFolders", endpoints.musicFolders())
            case .getArtists:
                return ok("artists", try await endpoints.artists())
            case .getArtist:
                return ok("artist", try await endpoints.artist(request))
            case .getAlbum:
                return ok("album", try await endpoints.album(request))
            case .getAlbumList2:
                return ok("albumList2", try await endpoints.albumList(request))
            case .getSong:
                return ok("song", try await endpoints.song(request))
            case .search3:
                return ok("searchResult3", try await endpoints.search(request))
            case .getPlaylists:
                return ok("playlists", try await endpoints.playlists())
            case .getPlaylist:
                return ok("playlist", try await endpoints.playlist(request))
            case .getStarred2:
                return ok("starred2", try await endpoints.starred())
            // These answer with the bytes themselves. A failure is still an
            // envelope, which a client tells apart by its content type.
            case .stream, .download:
                return try await endpoints.audio(request)
            case .getCoverArt:
                return try await endpoints.coverArt(request)
            }
        } catch let refusal as EndpointFailure {
            return failure(refusal.code, refusal.message)
        } catch {
            // Whatever the store said stays here. An error's description can
            // hold a path or a query, and a client is owed neither.
            return failure(.generic, "The library could not be read.")
        }
    }

    private func ok(_ key: String, _ value: some Encodable & Sendable) -> HTTPResponse {
        SubsonicResponse.ok(key, value, serverVersion: configuration.serverVersion).httpResponse()
    }

    // MARK: - Pairing

    /// Exactly one of `token` (from the QR code) and `code` (typed).
    private struct PairingRequest: Decodable {
        var token: String?
        var code: String?
        var name: String
    }

    private struct PairingResponse: Encodable {
        var apiKey: String
        var deviceId: String
        var serverVersion: String
        var cadenceProtocolVersion: Int
    }

    /// `POST /pair` — the one request that changes anything, and the one a
    /// device can make without a key, since getting a key is its purpose.
    ///
    /// It is not part of the library API and sits outside `/rest/` to say so.
    /// It can add a paired device and do nothing else. It only works while
    /// the user has a pairing code on screen; `PairingSession` holds the
    /// rules that make a six-digit code safe to accept.
    private func pair(_ request: HTTPRequest) async -> HTTPResponse {
        guard let pairing else { return .empty(.notFound) }
        guard request.method == .post else { return .empty(.methodNotAllowed) }
        // Exactly JSON. A browser cannot send this content type across
        // origins without asking first, which keeps a web page the user
        // happens to have open from making this request for them.
        let contentType = request.headers["content-type"]?
            .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard contentType == "application/json" else { return .empty(.unsupportedMediaType) }
        guard let body = try? JSONDecoder().decode(PairingRequest.self, from: request.body) else {
            return .empty(.badRequest)
        }

        let paired: (device: PairedDevice, apiKey: String)?
        switch (body.token, body.code) {
        case (let token?, nil):
            paired = await pairing.redeem(token: token, deviceName: body.name)
        case (nil, let code?):
            paired = await pairing.redeem(code: code, deviceName: body.name)
        default:
            return .empty(.badRequest)
        }
        guard let paired else {
            // One answer for wrong, expired, used up and not open.
            return Self.json(.forbidden, ["error": "pairing_failed"])
        }
        return Self.json(.ok, PairingResponse(
            apiKey: paired.apiKey,
            deviceId: paired.device.id.uuidString.lowercased(),
            serverVersion: configuration.serverVersion,
            cadenceProtocolVersion: SubsonicResponse.cadenceProtocolVersion))
    }

    private static func json(_ status: HTTPStatus, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8",
                            body: (try? encoder.encode(value)) ?? Data("{}".utf8))
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
        guard await authenticator.device(forAPIKey: key) != nil else {
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
