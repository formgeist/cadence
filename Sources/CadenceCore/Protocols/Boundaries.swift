import Foundation

// MARK: - Player engine

/// Discrete things the engine reports. Position is a separate stream.
public enum EngineEvent: Sendable, Equatable {
    case started(URL)
    case paused
    case resumed
    /// Emitted as soon as a track begins, asking the controller for the next
    /// URL. The gapless handshake starts here, not near the end of the track —
    /// see PLAN.md §7.
    case wantsNextTrack
    /// The engine transitioned to the queued track by itself. The controller
    /// follows; it does not drive this.
    case advancedToNext(URL)
    case finished
    /// The output device went away — headphones unplugged, an interface
    /// disconnected. Distinct from `failed` because the track is still
    /// perfectly good; only the destination changed.
    case outputDeviceLost
    case failed(PlaybackError)
}

/// The audio engine boundary. Takes URLs and gain values — it never sees the
/// database, which is what makes `MockPlayerEngine` possible and swapping
/// SFBAudioEngine out cheap.
@MainActor
public protocol PlayerEngine: AnyObject {
    /// Discrete state changes.
    var events: AsyncStream<EngineEvent> { get }
    /// Position ticks, roughly 10×/second while playing.
    var positions: AsyncStream<TimeInterval> { get }

    var volume: Double { get set }
    var currentTime: TimeInterval { get }

    /// Stop whatever is playing and start this file. `gain` is linear
    /// amplitude, already resolved from ReplayGain by the controller.
    func play(url: URL, duration: TimeInterval, gain: Double) throws
    /// Hand the engine the next file so it can transition without a gap.
    func prepareNext(url: URL, duration: TimeInterval, gain: Double) throws
    /// Withdraw a previously prepared track — the queue changed under it.
    func clearNext()

    func pause()
    func resume()
    func stop()
    func seek(to time: TimeInterval)
}

// MARK: - Metadata

/// Reads tags off a file. Implementations are expected to be forgiving:
/// `TRACKNUMBER=3/12`, multiple ARTIST fields, `DATE=1969-08-15` and missing
/// STREAMINFO values are all normal in the wild — see PLAN.md §7.
public protocol MetadataReader: Sendable {
    func readTrack(at url: URL) throws -> Track
    func readArtwork(at url: URL) throws -> Data?
    /// Both in a single pass. The scanner wants tags and cover for every file,
    /// and reading twice doubles the syscalls across a library.
    func readTrackAndArtwork(at url: URL) throws -> (track: Track, artwork: Data?)
}

extension MetadataReader {
    /// Correct for any reader; implementations that can genuinely do it in one
    /// read should override.
    public func readTrackAndArtwork(at url: URL) throws -> (track: Track, artwork: Data?) {
        (try readTrack(at: url), try readArtwork(at: url))
    }
}

/// Picks a reader by file extension.
///
/// FLAC has a dedicated pure-Swift reader that needs no audio library; every
/// other format goes to SFB. Which reader handles what is a composition
/// decision, so it lives here rather than inside the scanner.
public struct MetadataRouter: Sendable {
    private let readers: [String: any MetadataReader]

    /// Keys are lowercased file extensions.
    public init(_ readers: [String: any MetadataReader]) {
        self.readers = readers.reduce(into: [:]) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
    }

    /// Builds a router from one reader and the extensions it claims.
    public init(_ reader: any MetadataReader, extensions: Set<String>) {
        self.init(extensions.reduce(into: [:]) { $0[$1] = reader })
    }

    public var supportedExtensions: Set<String> { Set(readers.keys) }

    public func reader(for url: URL) -> (any MetadataReader)? {
        readers[url.pathExtension.lowercased()]
    }

    /// Later routers win on conflicts, so a caller can layer a specialised
    /// reader over a general one.
    public func merging(_ other: MetadataRouter) -> MetadataRouter {
        MetadataRouter(readers.merging(other.readers) { _, new in new })
    }
}

// MARK: - Library

public protocol LibraryStore: Sendable {
    func allTracks() async throws -> [Track]
    func albums() async throws -> [Album]
    func album(for key: Album.Key) async throws -> Album?
    func artists() async throws -> [Artist]
    func albums(byArtist name: String) async throws -> [Album]
    func playlists() async throws -> [Playlist]
    /// Creates an empty playlist and returns it, so the caller can select the
    /// row it just made without guessing which of several same-named
    /// playlists is the new one.
    @discardableResult
    func createPlaylist(named name: String) async throws -> Playlist
    /// Appends to the end of one playlist. Ids with no track behind them are
    /// skipped rather than failing the batch — dragging a stale selection in
    /// should add what still exists.
    func addTracks(_ trackIDs: [Track.ID], to playlistID: Playlist.ID) async throws
    /// Offsets into the playlist's own order, the way `onDelete` hands them
    /// over. By offset rather than by track id because a playlist may hold the
    /// same track twice, and then an id names two rows.
    func removeTracks(atOffsets offsets: IndexSet, from playlistID: Playlist.ID) async throws
    /// Offsets and destination are SwiftUI's `onMove` semantics.
    func moveTracks(fromOffsets source: IndexSet, toOffset destination: Int,
                    in playlistID: Playlist.ID) async throws
    func renamePlaylist(_ id: Playlist.ID, to name: String) async throws
    func deletePlaylist(_ id: Playlist.ID) async throws
    func tracks(matching query: String) async throws -> [Track]
    func upsert(_ tracks: [Track]) async throws
    /// Removes tracks from the library outright — not from one playlist, from
    /// every one of them, via the cascade on `playlistItem.trackID`. Does not
    /// touch the file on disk.
    func remove(trackIDs: [Track.ID]) async throws
    /// Total bytes on disk, for the sidebar footer.
    func librarySize() async throws -> Int64

    /// Artist name → the artwork id the user chose for that artist, overriding
    /// the first-album-cover default. Empty by default: an in-memory store used
    /// by previews and tests need not carry the override.
    func customArtistImages() async throws -> [String: Artwork.ID]
    /// Sets (or, with `nil`, clears) the custom image for one artist. The bytes
    /// themselves live in the `ArtworkStore`; this only records which id an
    /// artist points at.
    func setCustomArtistImage(_ id: Artwork.ID?, forArtist name: String) async throws
}

extension LibraryStore {
    public func customArtistImages() async throws -> [String: Artwork.ID] { [:] }
    public func setCustomArtistImage(_ id: Artwork.ID?, forArtist name: String) async throws {}
}

// MARK: - Settings

/// Keys `SettingsStore` values are filed under — a closed set, so a typo in a
/// key string can't silently open a new, disconnected slot.
public enum SettingsKey: String, Sendable {
    case volume, isMuted, volumeBeforeMute
    case shuffleMode, repeatMode, replayGainMode
    case tab, gridZoom
    case artistSort, albumSort
    /// JSON-encoded `[String]` — recent search terms and recently played
    /// track ids, most-recent first. See #72.
    case recentSearches, recentlyPlayed
    /// JSON-encoded `[AppModel.RecentPlay]` — the albums and playlists behind
    /// the Recents grid, most-recent first.
    case recentPlays
    /// The queue across a relaunch — see #42. `queueTrackIDs` and
    /// `queueOrderedTrackIDs` are JSON-encoded `[String]` of track ids, in
    /// play order and in pre-shuffle order respectively; `queueCurrentTrackID`
    /// is the one that was playing, and `queuePosition` how far into it;
    /// `queuePlaylistOrigin` is the playlist the queue was started from, if
    /// any, so a resumed playlist keeps crediting the playlist in Recents.
    case queueTrackIDs, queueOrderedTrackIDs, queueCurrentTrackID, queuePosition
    case queuePlaylistOrigin
    /// Scrobbling — see #95. `scrobblingEnabled` is the on/off switch;
    /// `scrobbleService` and `scrobbleUsername` name the connected account
    /// (the session key itself lives in the keychain, not here);
    /// `pendingScrobbles` is a JSON-encoded `[ScrobblePlay]` held for retry
    /// when the network is down.
    case scrobblingEnabled, scrobbleService, scrobbleUsername, pendingScrobbles
}

/// Small pieces of state that should survive a relaunch — volume, mute,
/// shuffle, the selected tab — see #42. `PlaybackController` and `AppModel`
/// live above where the app runs and know nothing about `UserDefaults`
/// (PLAN.md §5), so persistence is injected the same way the engine is
/// rather than reached for directly.
@MainActor
public protocol SettingsStore: AnyObject {
    func double(forKey key: SettingsKey) -> Double?
    func set(_ value: Double?, forKey key: SettingsKey)
    func bool(forKey key: SettingsKey) -> Bool?
    func set(_ value: Bool?, forKey key: SettingsKey)
    func string(forKey key: SettingsKey) -> String?
    func set(_ value: String?, forKey key: SettingsKey)
}

// MARK: - Artwork

public protocol ArtworkStore: Sendable {
    /// Content-addressed by SHA-256 of the bytes; returns the existing ID when
    /// the same cover is already on disk.
    func store(_ data: Data) async throws -> Artwork.ID
    /// Always a thumbnail, never the full-resolution image. A 200-album grid
    /// of full-size JPEGs is hundreds of megabytes — see PLAN.md §7.
    func thumbnail(for id: Artwork.ID, maxPixelSize: Int) async throws -> Data?
    func full(for id: Artwork.ID) async throws -> Data?
}
