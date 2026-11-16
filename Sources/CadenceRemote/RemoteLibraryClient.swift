import Foundation

/// A paired device's connection to a Mac's library: one typed method per
/// endpoint the server offers.
///
/// Every request goes over TLS 1.3 to the paired server, whose certificate is
/// checked against the pinned fingerprint before anything is sent, and
/// carries this device's API key. Every failure is a `RemoteError`, except
/// cancellation, which is a `CancellationError`.
///
/// Nothing is read-write: the library API has no write path.
public final class RemoteLibraryClient: Sendable {

    /// The version of Cadence's protocol this client speaks. A server that
    /// reports a different one is refused with `.incompatibleServer`, so that
    /// mismatched app and server releases fail with a clear message, not a
    /// decode error halfway through a screen.
    public static let protocolVersion = 1

    /// The Subsonic API version requests say they follow.
    static let apiVersion = "1.16.1"

    public let credentials: RemoteCredentials
    private let session: PinnedSession

    /// - Parameter timeout: Seconds to wait for each answer. Short, so that
    ///   a Mac that is asleep is reported as unreachable promptly.
    public init(credentials: RemoteCredentials, timeout: TimeInterval = 15) {
        self.credentials = credentials
        session = PinnedSession(fingerprint: credentials.server.fingerprint, timeout: timeout)
    }

    deinit { session.invalidate() }

    // MARK: - Server

    /// What `connect()` learns about the server.
    public struct ServerInfo: Sendable, Equatable {
        /// The Cadence release on the Mac, for display.
        public var serverVersion: String
        public var protocolVersion: Int
    }

    /// Checks that the server is the paired one, that it still accepts this
    /// device, and that it speaks this client's protocol. Call it before
    /// showing the library, and again after the network comes back.
    @discardableResult
    public func connect() async throws -> ServerInfo {
        let body = try await envelope("ping", [])
        // `envelope` refuses a different version; a missing one is refused
        // here, since ping is where the version is promised.
        guard let version = body.cadenceProtocolVersion else {
            throw RemoteError.incompatibleServer(
                serverVersion: body.serverVersion ?? "unknown", protocolVersion: nil)
        }
        return ServerInfo(serverVersion: body.serverVersion ?? "unknown", protocolVersion: version)
    }

    // MARK: - Browsing

    /// Every artist, grouped under index letters, in the server's order.
    public func artists() async throws -> [RemoteArtistIndex] {
        try await payload("getArtists", "artists", [], as: ArtistsPayload.self).index ?? []
    }

    /// An artist with its albums.
    public func artist(id: String) async throws -> RemoteArtist {
        try await payload("getArtist", "artist", [.init(name: "id", value: id)])
    }

    /// An album with its songs, in disc and track order.
    public func album(id: String) async throws -> RemoteAlbum {
        try await payload("getAlbum", "album", [.init(name: "id", value: id)])
    }

    /// One page of albums. `size` is capped by the server.
    public func albums(
        _ order: RemoteAlbumOrder, size: Int = 50, offset: Int = 0
    ) async throws -> [RemoteAlbum] {
        try await payload("getAlbumList2", "albumList2", order.parameters + [
            .init(name: "size", value: String(size)),
            .init(name: "offset", value: String(offset)),
        ], as: AlbumListPayload.self).album ?? []
    }

    public func song(id: String) async throws -> RemoteSong {
        try await payload("getSong", "song", [.init(name: "id", value: id)])
    }

    /// Artists, albums and songs matching `query`. An empty query is the
    /// whole library, a page at a time.
    public func search(
        _ query: String, artistCount: Int = 20, albumCount: Int = 20, songCount: Int = 20,
        songOffset: Int = 0
    ) async throws -> RemoteSearchResult {
        try await payload("search3", "searchResult3", [
            .init(name: "query", value: query),
            .init(name: "artistCount", value: String(artistCount)),
            .init(name: "albumCount", value: String(albumCount)),
            .init(name: "songCount", value: String(songCount)),
            .init(name: "songOffset", value: String(songOffset)),
        ])
    }

    /// Every playlist, without its songs, in the Mac's sidebar order.
    public func playlists() async throws -> [RemotePlaylist] {
        try await payload("getPlaylists", "playlists", [], as: PlaylistsPayload.self).playlist ?? []
    }

    /// A playlist with its songs, in playlist order.
    public func playlist(id: String) async throws -> RemotePlaylist {
        try await payload("getPlaylist", "playlist", [.init(name: "id", value: id)])
    }

    /// The artists, albums and songs liked on the Mac.
    public func starred() async throws -> RemoteStarred {
        try await payload("getStarred2", "starred2", [])
    }

    // MARK: - Files

    /// The song's original file, saved at `destination`. Replaces anything
    /// already there, and leaves nothing there when it fails.
    public func download(songID: String, to destination: URL) async throws {
        let request = try request("download", [.init(name: "id", value: songID)])
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard response.statusCode == 200, !Self.isJSON(response) else {
            // Errors are envelopes, small enough to read from the file.
            throw Self.failure(response, body: (try? Data(contentsOf: file)) ?? Data())
        }
        let manager = FileManager.default
        try? manager.createDirectory(at: destination.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        _ = try? manager.removeItem(at: destination)
        do {
            try manager.moveItem(at: file, to: destination)
        } catch {
            throw RemoteError.invalidResponse
        }
    }

    /// Cover art, as image bytes. With `size`, a thumbnail at least that
    /// many pixels on its long side; without, the full image.
    public func coverArt(id: String, size: Int? = nil) async throws -> Data {
        var parameters = [URLQueryItem(name: "id", value: id)]
        if let size { parameters.append(.init(name: "size", value: String(size))) }
        let (data, response) = try await session.data(for: try request("getCoverArt", parameters))
        guard response.statusCode == 200, !Self.isJSON(response) else {
            throw Self.failure(response, body: data)
        }
        return data
    }

    // MARK: - Requests

    private func request(_ endpoint: String, _ parameters: [URLQueryItem]) throws -> URLRequest {
        guard let base = credentials.server.baseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw RemoteError.invalidResponse }
        components.path = "/rest/\(endpoint)"
        components.queryItems = parameters + [
            .init(name: "apiKey", value: credentials.apiKey),
            .init(name: "f", value: "json"),
            .init(name: "c", value: "Cadence"),
            .init(name: "v", value: Self.apiVersion),
        ]
        // `URLComponents` leaves `+` alone in a query, where a server reads
        // it as a space. Keys and searches can contain one.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw RemoteError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func envelope(_ endpoint: String, _ parameters: [URLQueryItem]) async throws -> Envelope.Body {
        let (data, response) = try await session.data(for: try request(endpoint, parameters))
        return try Self.checked(response, data)
    }

    private func payload<Value: Decodable>(
        _ endpoint: String, _ key: String, _ parameters: [URLQueryItem], as type: Value.Type = Value.self
    ) async throws -> Value {
        let (data, response) = try await session.data(for: try request(endpoint, parameters))
        _ = try Self.checked(response, data)
        let decoder = JSONDecoder()
        decoder.userInfo[Payload<Value>.keyInfo] = key
        do {
            return try decoder.decode(Payload<Value>.self, from: data).value
        } catch {
            throw RemoteError.invalidResponse
        }
    }

    /// The envelope of a successful answer, or the error the answer stands
    /// for.
    static func checked(_ response: HTTPURLResponse, _ data: Data) throws -> Envelope.Body {
        guard response.statusCode == 200 else { throw failure(response, body: data) }
        guard let body = try? JSONDecoder().decode(Envelope.self, from: data).body else {
            throw RemoteError.invalidResponse
        }
        try checkVersion(body)
        if let error = body.error { throw mapped(error) }
        guard body.status == "ok" else { throw RemoteError.invalidResponse }
        return body
    }

    /// The error for an answer that is not a success: a status, or an
    /// envelope with the protocol's error in it.
    static func failure(_ response: HTTPURLResponse, body data: Data) -> RemoteError {
        if response.statusCode == 429 {
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .busy(retryAfter: seconds ?? 1)
        }
        if let body = try? JSONDecoder().decode(Envelope.self, from: data).body {
            if let mismatch = versionMismatch(body) { return mismatch }
            if let error = body.error { return mapped(error) }
        }
        return .invalidResponse
    }

    /// Checked on every answer, not only at `connect()`: a Mac updated while
    /// the app was open is caught on the next request.
    private static func checkVersion(_ body: Envelope.Body) throws {
        if let mismatch = versionMismatch(body) { throw mismatch }
    }

    private static func versionMismatch(_ body: Envelope.Body) -> RemoteError? {
        guard let version = body.cadenceProtocolVersion, version != protocolVersion else { return nil }
        return .incompatibleServer(serverVersion: body.serverVersion ?? "unknown",
                                   protocolVersion: version)
    }

    private static func mapped(_ error: Envelope.Failure) -> RemoteError {
        switch error.code {
        // No key, a wrong one, or a mechanism this server refuses: in every
        // case this device's way in is gone, and pairing again is the fix.
        case 40, 41, 42, 43, 44: .notPaired
        case 70: .notFound
        default: .server(code: error.code, message: error.message ?? "")
        }
    }

    private static func isJSON(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().hasPrefix("application/json") ?? false
    }
}
