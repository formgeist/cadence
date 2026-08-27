import Foundation

// MARK: - What gets scrobbled

/// One play, in the shape a scrobbling service wants it: names and a start
/// time, nothing about files or the library. `Codable` because the offline
/// queue is persisted as JSON through `SettingsStore`.
public struct ScrobblePlay: Codable, Sendable, Equatable {
    public var artist: String
    public var track: String
    public var album: String?
    public var albumArtist: String?
    /// Seconds. Last.fm uses it to decide whether a submission is plausible.
    public var duration: TimeInterval
    /// When the track started playing — the scrobble's timestamp, not the
    /// moment it crossed the threshold.
    public var startedAt: Date

    public init(artist: String, track: String, album: String? = nil,
                albumArtist: String? = nil, duration: TimeInterval, startedAt: Date) {
        self.artist = artist
        self.track = track
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.startedAt = startedAt
    }

    public init(track: Track, startedAt: Date) {
        self.init(
            artist: track.artist,
            track: track.title,
            album: track.albumTitle.isEmpty ? nil : track.albumTitle,
            // Only worth sending when it actually differs from the track artist.
            albumArtist: track.albumArtist == track.artist ? nil : track.albumArtist,
            duration: track.duration,
            startedAt: startedAt
        )
    }
}

/// A resolved account: the durable key a service hands back after the web auth
/// flow, plus the username it belongs to. The key is a secret and lives in the
/// keychain, never in `SettingsStore`.
public struct ScrobbleSession: Sendable, Equatable {
    public var key: String
    public var username: String

    public init(key: String, username: String) {
        self.key = key
        self.username = username
    }
}

// MARK: - The service boundary

/// One scrobbling target — Last.fm today, ListenBrainz behind the same shape
/// later. The controller drives all of this; an implementation is a stateless
/// translator between `ScrobblePlay` and an HTTP API.
public protocol Scrobbler: Sendable {
    /// For the keychain account name and the "Scrobble to …" label.
    var serviceName: String { get }
    /// False when no API credentials were compiled in — the UI disables
    /// connecting rather than offering a flow that cannot complete.
    var isConfigured: Bool { get }

    /// Step one of the web auth flow: a URL to open in the browser, and the
    /// token to poll `completeAuthorization` with once the user has approved.
    func beginAuthorization() async throws -> (url: URL, token: String)
    /// Step two, polled until it stops throwing `authorizationPending`.
    func completeAuthorization(token: String) async throws -> ScrobbleSession

    /// "Now playing" — best effort, never queued. A missed one is invisible.
    func updateNowPlaying(_ play: ScrobblePlay, session: ScrobbleSession) async throws
    /// Submit a batch. Throwing leaves the whole batch queued for retry;
    /// returning normally means every play in it was accepted.
    func submit(_ plays: [ScrobblePlay], session: ScrobbleSession) async throws
}

/// Why a scrobble call failed, in the terms the controller reasons about:
/// keep-and-retry, drop-the-session, or drop-the-play.
public enum ScrobbleError: Error, Equatable {
    /// No API key/secret compiled in.
    case notConfigured
    /// The network was unreachable or the service was briefly unavailable —
    /// keep the queue and try again later.
    case transient(String)
    /// The session key is no longer valid (Last.fm error 9). The user has to
    /// reconnect; the queue is held until they do.
    case needsReauthorization
    /// The auth token has not been approved in the browser yet — expected
    /// while polling `completeAuthorization`.
    case authorizationPending
    /// The service rejected the request for a reason that will not fix itself
    /// (bad parameters, a play too old to accept). The play is dropped.
    case rejected(String)
    /// A response that did not parse.
    case malformedResponse
}

// MARK: - Secret storage

/// The keychain, as the one secret the scrobbler holds needs it. A protocol so
/// previews and tests use an in-memory stand-in — the same reason
/// `SettingsStore` is one.
public protocol KeychainStore: Sendable {
    func string(forAccount account: String) -> String?
    /// `nil` deletes the item.
    func set(_ value: String?, forAccount account: String)
}
