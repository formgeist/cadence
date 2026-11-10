import Foundation
import Observation
import CadenceCore

/// Similar artists and albums for the detail pages. Owns the
/// `SimilarityIndex` and keeps it in step with the library, the playlists and
/// the listening history, and adds Last.fm's answers when the listener has
/// turned that on.
///
/// The index is rebuilt lazily — on the next query after anything it is built
/// from has changed — and off the main actor, so a big library never stalls a
/// page while it opens.
@MainActor
@Observable
final class DiscoveryController {
    struct ArtistResults: Equatable {
        /// Artists in the library, strongest first.
        var inLibrary: [SimilarArtist] = []
        /// Last.fm's suggestions that are not in the library, for the
        /// listener to look up. Empty when Last.fm is off.
        var elsewhere: [ExternalSimilarArtist] = []
    }

    /// Off by default: turning it on sends the names of artists the listener
    /// opens to Last.fm.
    var usesLastFM: Bool {
        didSet { settings.set(usesLastFM, forKey: .similarArtistsFromLastFM) }
    }

    /// False when the build has no Last.fm API key, or in preview mode.
    var isLastFMAvailable: Bool { lookup?.isConfigured ?? false }

    /// How many artists have a Last.fm answer stored. Nil until counted.
    private(set) var cachedArtistCount: Int?
    private(set) var isRefreshing = false
    /// Bumped by `refreshLastFM`, so an artist or album page already on
    /// screen asks again instead of keeping the answer it had.
    private(set) var lastFMRevision = 0

    private let model: AppModel
    private let playLog: PlayLogController
    private let settings: any SettingsStore
    private let lookup: SimilarArtistLookup?

    private var index: SimilarityIndex?
    private var indexStamp: Stamp?
    private var building: (stamp: Stamp, task: Task<SimilarityIndex, Never>)?

    /// What the index was built from. Counts and generations rather than the
    /// data itself, so checking it costs nothing.
    private struct Stamp: Equatable {
        var library: Int
        var playlists: Int
        var plays: Int
    }

    init(model: AppModel, playLog: PlayLogController, settings: any SettingsStore,
         lookup: SimilarArtistLookup?) {
        self.model = model
        self.playLog = playLog
        self.settings = settings
        self.lookup = lookup
        usesLastFM = settings.bool(forKey: .similarArtistsFromLastFM) ?? false
    }

    func countCachedArtists() async {
        cachedArtistCount = await lookup?.cachedCount() ?? 0
    }

    /// Forgets Last.fm's stored answers. Each artist is asked again the next
    /// time its page opens; a page on screen now asks straight away.
    func refreshLastFM() async {
        guard let lookup, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        try? await lookup.clearCache()
        cachedArtistCount = await lookup.cachedCount()
        lastFMRevision += 1
    }

    func similarArtists(to name: String, limit: Int = 12) async -> ArtistResults {
        let external = await externalSimilar(to: name)
        let index = await currentIndex()
        let inLibrary = index.artists(similarTo: name, external: external, limit: limit)
        let elsewhere = external
            .filter { index.libraryName(for: $0.name) == nil }
            .prefix(8)
        return ArtistResults(inLibrary: inLibrary, elsewhere: Array(elsewhere))
    }

    func similarAlbums(to key: Album.Key, limit: Int = 10) async -> [SimilarAlbum] {
        let external = await externalSimilar(to: key.albumArtist)
        let index = await currentIndex()
        // A wider net of artists than the artist page shows: an album two
        // dozen artists down the list can still be the best album match.
        let artists = index.artists(similarTo: key.albumArtist, external: external, limit: 40)
        return index.albums(similarTo: key, artists: artists, limit: limit)
    }

    private func externalSimilar(to artist: String) async -> [ExternalSimilarArtist] {
        guard usesLastFM, let lookup else { return [] }
        let result = await lookup.similarArtists(to: artist)
        // Keeps the Preferences figure honest once a new artist is cached.
        cachedArtistCount = await lookup.cachedCount()
        return result
    }

    private func currentIndex() async -> SimilarityIndex {
        let stamp = Stamp(
            library: model.libraryGeneration,
            playlists: model.playlists.reduce(into: Hasher()) { hasher, playlist in
                hasher.combine(playlist.id)
                hasher.combine(playlist.trackIDs.count)
            }.finalize(),
            plays: playLog.plays.count)
        if let index, indexStamp == stamp { return index }
        if let building, building.stamp == stamp { return await building.task.value }

        let albums = model.albums
        let playlists = model.playlists
        let plays = playLog.plays
        let task = Task.detached(priority: .userInitiated) {
            SimilarityIndex(albums: albums, playlists: playlists, plays: plays)
        }
        building = (stamp, task)
        let built = await task.value
        // A newer build may have started while this one ran; only the newest
        // gets to be the index.
        if building?.stamp == stamp {
            index = built
            indexStamp = stamp
            building = nil
        }
        return built
    }
}
