import Foundation
import CadenceLibrary

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
    private let endpoints: LibraryEndpoints

    /// The server reads `library` and never writes to it: it calls no method
    /// of the store that changes anything.
    public init(configuration: Configuration, authenticator: any Authenticator,
                library: SQLiteLibraryStore, artwork: DiskArtworkStore? = nil) {
        self.configuration = configuration
        self.authenticator = authenticator
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
