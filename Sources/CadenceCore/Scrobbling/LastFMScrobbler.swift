import Foundation
import CryptoKit

/// Last.fm's Audioscrobbler 2.0 API. Pure Foundation plus CryptoKit for the
/// request signature — no third-party code, so it stays in `CadenceCore`.
///
/// The flow the app drives:
///  1. `beginAuthorization` → `auth.getToken`, then open
///     `last.fm/api/auth/?api_key=…&token=…` in the browser.
///  2. `completeAuthorization` → `auth.getSession`, polled until the user has
///     clicked "Yes, allow access".
///  3. `updateNowPlaying` / `submit` → `track.updateNowPlaying` /
///     `track.scrobble`, signed with the session key.
public struct LastFMScrobbler: Scrobbler {
    public let serviceName = "Last.fm"

    private let apiKey: String
    private let sharedSecret: String
    private let session: URLSession
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private let authPage = "https://www.last.fm/api/auth/"

    public init(apiKey: String, sharedSecret: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.sharedSecret = sharedSecret
        self.session = session
    }

    public var isConfigured: Bool { !apiKey.isEmpty && !sharedSecret.isEmpty }

    // MARK: - Auth

    public func beginAuthorization() async throws -> (url: URL, token: String) {
        guard isConfigured else { throw ScrobbleError.notConfigured }
        let json = try await call(["method": "auth.getToken"], signed: true, write: false)
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw ScrobbleError.malformedResponse
        }
        var components = URLComponents(string: authPage)!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = components.url else { throw ScrobbleError.malformedResponse }
        return (url, token)
    }

    public func completeAuthorization(token: String) async throws -> ScrobbleSession {
        guard isConfigured else { throw ScrobbleError.notConfigured }
        let json = try await call(
            ["method": "auth.getSession", "token": token], signed: true, write: false)
        guard let session = json["session"] as? [String: Any],
              let key = session["key"] as? String,
              let name = session["name"] as? String else {
            throw ScrobbleError.malformedResponse
        }
        return ScrobbleSession(key: key, username: name)
    }

    // MARK: - Scrobbling

    public func updateNowPlaying(_ play: ScrobblePlay, session: ScrobbleSession) async throws {
        var params = [
            "method": "track.updateNowPlaying",
            "artist": play.artist,
            "track": play.track,
            "duration": String(Int(play.duration.rounded())),
            "sk": session.key,
        ]
        if let album = play.album { params["album"] = album }
        if let albumArtist = play.albumArtist { params["albumArtist"] = albumArtist }
        _ = try await call(params, signed: true, write: true)
    }

    public func submit(_ plays: [ScrobblePlay], session: ScrobbleSession) async throws {
        guard !plays.isEmpty else { return }
        var params = ["method": "track.scrobble", "sk": session.key]
        for (i, play) in plays.enumerated() {
            params["artist[\(i)]"] = play.artist
            params["track[\(i)]"] = play.track
            params["timestamp[\(i)]"] = String(Int(play.startedAt.timeIntervalSince1970))
            params["duration[\(i)]"] = String(Int(play.duration.rounded()))
            if let album = play.album { params["album[\(i)]"] = album }
            if let albumArtist = play.albumArtist { params["albumArtist[\(i)]"] = albumArtist }
        }
        _ = try await call(params, signed: true, write: true)
    }

    // MARK: - Transport

    /// Every call is `application/x-www-form-urlencoded`. `format=json` is added
    /// to the request but never to the signature.
    private func call(
        _ params: [String: String], signed: Bool, write: Bool
    ) async throws -> [String: Any] {
        var params = params
        params["api_key"] = apiKey
        if signed {
            params["api_sig"] = Self.signature(params, secret: sharedSecret)
        }
        params["format"] = "json"

        var request = URLRequest(url: endpoint)
        request.httpMethod = write ? "POST" : "GET"
        let body = Self.formEncode(params)
        if write {
            request.setValue("application/x-www-form-urlencoded",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        } else {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.percentEncodedQuery = body
            request.url = components.url
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ScrobbleError.transient(error.localizedDescription)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScrobbleError.malformedResponse
        }
        if let code = json["error"] as? Int {
            throw Self.mapError(code: code,
                                message: json["message"] as? String ?? "Last.fm error \(code)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
            throw ScrobbleError.transient("Last.fm is temporarily unavailable (\(http.statusCode)).")
        }
        return json
    }

    /// Maps Last.fm's numeric error codes onto the three outcomes the
    /// controller cares about. See https://www.last.fm/api/errorcodes.
    private static func mapError(code: Int, message: String) -> ScrobbleError {
        switch code {
        case 9: .needsReauthorization                 // invalid session key
        case 14: .authorizationPending                 // token not authorized yet
        case 11, 16, 29: .transient(message)           // service down / rate limited
        case 8: .transient(message)                    // operation failed, try again
        default: .rejected(message)                    // 4, 6, 7, 13, 15, … — won't self-heal
        }
    }

    // MARK: - Signing

    /// The API signature: every parameter except `format`, sorted by name,
    /// concatenated as `name` + `value` with no separators, the shared secret
    /// appended, then MD5 as lowercase hex.
    static func signature(_ params: [String: String], secret: String) -> String {
        let joined = params
            .filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined()
        let digest = Insecure.MD5.hash(data: Data((joined + secret).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
