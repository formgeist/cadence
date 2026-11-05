import Foundation
import CryptoKit

/// The slice of Spotify's Web API the playlist importer needs: sign in with
/// Authorization Code + PKCE, then read one playlist's name and entries.
///
/// Since Spotify's February 2026 changes, a playlist's entries come back only
/// for playlists the signed-in user owns or collaborates on, and only with a
/// user token — a client-credentials token gets the playlist's metadata and
/// no `items`. Hence a real sign-in rather than an app key. PKCE because a
/// desktop app cannot keep a client secret: only the client id is compiled in.
///
/// Pure Foundation plus CryptoKit, like `LastFMScrobbler`, so it stays in
/// `CadenceCore`. The browser half of the sign-in lives in the app target.
public struct SpotifyAPI: Sendable {
    public let clientID: String
    public let redirectURI: String
    private let session: URLSession

    public static let scopes = ["playlist-read-private", "playlist-read-collaborative"]

    private static let authorizeEndpoint = URL(string: "https://accounts.spotify.com/authorize")!
    private static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    private static let apiBase = URL(string: "https://api.spotify.com/v1/")!

    public init(clientID: String, redirectURI: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.session = session
    }

    public var isConfigured: Bool { !clientID.isEmpty }

    // MARK: - Sign-in

    /// One sign-in attempt: the verifier stays here, the challenge goes out in
    /// the URL, and `state` comes back with the code so a stray redirect is
    /// refused.
    public struct Authorization: Sendable {
        public let url: URL
        public let verifier: String
        public let state: String
    }

    public func beginAuthorization() -> Authorization {
        let verifier = Self.randomURLSafeString(byteCount: 64)
        let state = Self.randomURLSafeString(byteCount: 16)
        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        return Authorization(url: components.url!, verifier: verifier, state: state)
    }

    /// Pulls the code out of the redirect Spotify sent the browser to.
    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw error == "access_denied" ? SpotifyError.accessDenied : SpotifyError.api(error)
        }
        guard value("state") == expectedState else { throw SpotifyError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw SpotifyError.malformedResponse }
        return code
    }

    public func exchange(code: String, verifier: String) async throws -> SpotifyToken {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ], previousRefreshToken: nil)
    }

    /// Spotify may or may not rotate the refresh token; when it does not, the
    /// old one stays good and is carried over.
    public func refresh(_ token: SpotifyToken) async throws -> SpotifyToken {
        try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": clientID,
        ], previousRefreshToken: token.refreshToken)
    }

    private func tokenRequest(_ form: [String: String],
                              previousRefreshToken: String?) async throws -> SpotifyToken {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let json = try Self.jsonObject(data)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if json["error"] as? String == "invalid_grant" { throw SpotifyError.signedOut }
            throw SpotifyError.api(json["error_description"] as? String
                                   ?? json["error"] as? String ?? "Token request failed")
        }
        return try Self.parseToken(json, previousRefreshToken: previousRefreshToken)
    }

    static func parseToken(_ json: [String: Any], previousRefreshToken: String?,
                           now: Date = Date()) throws -> SpotifyToken {
        guard let access = json["access_token"] as? String,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue,
              let refresh = (json["refresh_token"] as? String) ?? previousRefreshToken else {
            throw SpotifyError.malformedResponse
        }
        return SpotifyToken(accessToken: access, refreshToken: refresh,
                            expiresAt: now.addingTimeInterval(expiresIn))
    }

    // MARK: - Playlists

    /// The playlist's name and every entry, page by page.
    public func playlist(id: String, token: SpotifyToken) async throws -> SpotifyPlaylist {
        var nameURL = URLComponents(url: Self.apiBase.appending(path: "playlists/\(id)"),
                                    resolvingAgainstBaseURL: false)!
        nameURL.queryItems = [URLQueryItem(name: "fields", value: "name")]
        let meta = try await get(nameURL.url!, token: token)
        let name = meta["name"] as? String ?? "Spotify Playlist"

        var itemsURL = URLComponents(url: Self.apiBase.appending(path: "playlists/\(id)/items"),
                                     resolvingAgainstBaseURL: false)!
        itemsURL.queryItems = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "additional_types", value: "track"),
        ]
        var next: URL? = itemsURL.url
        var tracks: [SpotifyTrack] = []
        while let url = next {
            let page = try await get(url, token: token)
            tracks += Self.parseTracks(page)
            next = (page["next"] as? String).flatMap(URL.init(string:))
        }
        return SpotifyPlaylist(name: name, tracks: tracks)
    }

    private func get(_ url: URL, token: SpotifyToken) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try Self.jsonObject(data)
        case 401: throw SpotifyError.signedOut
        // The items endpoint answers 403 for a playlist the user neither owns
        // nor collaborates on — the case worth explaining in words.
        case 403: throw SpotifyError.notYourPlaylist
        case 404: throw SpotifyError.playlistNotFound
        default:
            let json = (try? Self.jsonObject(data)) ?? [:]
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw SpotifyError.api(message ?? "Spotify answered \(status)")
        }
    }

    /// One page of playlist entries. Reads `item` and falls back to the
    /// deprecated `track`; skips podcast episodes and removed tracks, which
    /// come back as `null`. Local files stay — they have a title and artist,
    /// and are likely the very files the library holds.
    static func parseTracks(_ page: [String: Any]) -> [SpotifyTrack] {
        let entries = page["items"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let item = (entry["item"] ?? entry["track"]) as? [String: Any],
                  (item["type"] as? String ?? "track") == "track",
                  let title = item["name"] as? String, !title.isEmpty else { return nil }
            let artists = (item["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .filter { !$0.isEmpty }
            let album = (item["album"] as? [String: Any])?["name"] as? String
            let ms = (item["duration_ms"] as? NSNumber)?.doubleValue ?? 0
            return SpotifyTrack(title: title, artists: artists,
                                album: album?.isEmpty == true ? nil : album,
                                duration: ms / 1000)
        }
    }

    /// Accepts what a person is likely to paste: a share link (with or
    /// without `?si=…`, with or without an `intl-xx` segment), a
    /// `spotify:playlist:…` URI, or the bare id.
    public static func playlistID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func isID(_ s: some StringProtocol) -> Bool {
            s.count >= 16 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }

        if trimmed.hasPrefix("spotify:") {
            let parts = trimmed.split(separator: ":")
            guard parts.count == 3, parts[1] == "playlist", isID(parts[2]) else { return nil }
            return String(parts[2])
        }
        if let url = URL(string: trimmed), let host = url.host(),
           host.hasSuffix("spotify.com") {
            let path = url.pathComponents.filter { $0 != "/" }
            guard let index = path.firstIndex(of: "playlist"), index + 1 < path.count,
                  isID(path[index + 1]) else { return nil }
            return path[index + 1]
        }
        return isID(trimmed) ? trimmed : nil
    }

    // MARK: - Helpers

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyError.malformedResponse
        }
        return json
    }
}

public struct SpotifyToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// A minute of slack, so a token does not expire between check and use.
    public func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < 60
    }
}

public struct SpotifyTrack: Hashable, Sendable {
    public var title: String
    public var artists: [String]
    public var album: String?
    public var duration: TimeInterval

    public init(title: String, artists: [String], album: String? = nil, duration: TimeInterval = 0) {
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
    }
}

public struct SpotifyPlaylist: Sendable {
    public var name: String
    public var tracks: [SpotifyTrack]
}

public enum SpotifyError: LocalizedError, Equatable {
    case notConfigured
    case accessDenied
    case stateMismatch
    case signedOut
    case notYourPlaylist
    case playlistNotFound
    case invalidLink
    case malformedResponse
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No Spotify client id is configured in this build."
        case .accessDenied: "Spotify sign-in was cancelled."
        case .stateMismatch: "Spotify sign-in did not match the request. Try again."
        case .signedOut: "Spotify sign-in has expired. Connect again."
        case .notYourPlaylist:
            "Spotify only shares the tracks of playlists you own or collaborate on."
        case .playlistNotFound: "Spotify could not find that playlist."
        case .invalidLink: "That does not look like a Spotify playlist link."
        case .malformedResponse: "Spotify sent a response Cadence could not read."
        case .api(let message): message
        }
    }
}
