import Foundation
import Observation
import CadenceCore

/// Navigation and library state for the window. Deliberately separate from
/// `PlaybackController`: what you are looking at and what you are listening to
/// are independent, and conflating them is what makes players lose your place
/// when a track changes.
@MainActor
@Observable
final class AppModel {

    enum Screen: Hashable {
        case library
        case album(Album.Key)
        /// Everything one artist has, by name — the same identity `Artist`
        /// uses, since an artist is not a row in a table here.
        case artist(String)
        /// By id, never by name: two playlists may share one.
        case playlist(Playlist.ID)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case artists = "Artists"
        case albums = "Albums"
        case playlists = "Playlists"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .artists: "person"
            case .albums: "circle.circle"
            case .playlists: "list.bullet"
            }
        }
    }

    // MARK: Navigation

    private(set) var screen: Screen = .library
    var tab: Tab = .artists
    var isImmersive = false
    /// A stack, so Back from an album reached through search returns to the
    /// search results' screen rather than guessing.
    private var backStack: [Screen] = []

    var canGoBack: Bool { !backStack.isEmpty }

    func show(_ screen: Screen) {
        guard screen != self.screen else { return }
        backStack.append(self.screen)
        self.screen = screen
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        screen = previous
    }

    // MARK: Search

    var searchText = "" {
        didSet { if !searchText.isEmpty { isSearching = true } }
    }
    var isSearching = false

    func endSearch() {
        isSearching = false
        searchText = ""
    }

    // MARK: Album grid zoom

    /// 0…1. The design's zoom slider; drives the grid's minimum column width.
    var gridZoom: Double = 0.4

    var albumColumnWidth: CGFloat {
        // 128pt at the small end holds a title and an artist without
        // truncating them into uselessness; 260 is where a 1280pt window still
        // shows more than three columns.
        128 + CGFloat(gridZoom) * 132
    }

    // MARK: Library

    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var playlists: [Playlist] = []
    private(set) var allTracks: [Track] = []
    private(set) var librarySize: Int64 = 0
    /// One cover per artist, chosen once at load. Asking for it per card meant
    /// scanning every album in the library on each row the grid drew.
    private var artistArtwork: [String: Artwork.ID] = [:]
    /// Playlists hold track ids; resolving one per row against `allTracks`
    /// would be a linear scan of the whole library for every line on screen.
    private var tracksByID: [Track.ID: Track] = [:]
    private(set) var isLoading = true
    private(set) var loadError: String?
    /// Set when the real database could not be opened and the preview library
    /// is standing in.
    var storeFailure: String?
    /// The last write that failed under the user's hand — creating a playlist,
    /// so far. Shown in the banner and dismissible, because a silent no-op
    /// looks like the button is broken.
    var actionError: String?
    /// The last write that succeeded somewhere you cannot see. Adding tracks
    /// to a playlist usually happens from an album, with the playlist itself
    /// off-screen; without a word it is indistinguishable from a dead menu.
    var notice: String?

    /// A freshly installed app with nothing imported yet. Distinct from a
    /// library that is still loading, which should not flash an empty state.
    var isEmpty: Bool { !isLoading && allTracks.isEmpty }

    let store: any LibraryStore

    init(store: any LibraryStore) {
        self.store = store
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            allTracks = try await store.allTracks()
            albums = Album.grouped(from: allTracks)
            artists = try await store.artists()
            playlists = try await store.playlists()
            librarySize = try await store.librarySize()
            artistArtwork = albums.reduce(into: [:]) { result, album in
                guard let artworkID = album.artworkID else { return }
                result[album.albumArtist] = result[album.albumArtist] ?? artworkID
            }
            tracksByID = Dictionary(allTracks.map { ($0.id, $0) }) { first, _ in first }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func album(for key: Album.Key) -> Album? {
        albums.first { $0.key == key }
    }

    /// An artist has no picture of their own; the first cover they released
    /// stands in, which is what every other music app does too.
    func artworkID(forArtist name: String) -> Artwork.ID? {
        artistArtwork[name]
    }

    func artist(named name: String) -> Artist? {
        artists.first { $0.name == name }
    }

    /// Every album credited to one artist, oldest first. The store has the
    /// same query, but the whole library is already in memory and the artist
    /// screen should not wait on a round trip to draw.
    func albums(byArtist name: String) -> [Album] {
        albums
            .filter { $0.albumArtist == name }
            .sorted {
                ($0.year ?? 0, $0.title.localizedLowercase)
                    < ($1.year ?? 0, $1.title.localizedLowercase)
            }
    }

    var currentAlbum: Album? {
        guard case .album(let key) = screen else { return nil }
        return album(for: key)
    }

    // MARK: Playlists

    /// What the naming sheet is for this time. One piece of state rather than
    /// two booleans: creating and renaming are the same dialog, and two sheets
    /// on one view is how you get neither.
    enum Naming: Identifiable, Hashable {
        /// `seed` is what an "Add to Playlist ▸ New Playlist…" was pointing
        /// at. Without it that route makes an empty playlist and drops the
        /// very tracks it was invoked on.
        case create(seed: [Track])
        case rename(Playlist)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let playlist): playlist.id.uuidString
            }
        }
    }

    /// Non-nil while the naming sheet is up — opened by the sidebar's plus,
    /// the empty state, and Rename.
    var naming: Naming?
    /// The playlist the confirmation dialog is asking about. Deleting is the
    /// one playlist action that cannot be undone.
    var playlistPendingDeletion: Playlist?

    func playlist(id: Playlist.ID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    var currentPlaylist: Playlist? {
        guard case .playlist(let id) = screen else { return nil }
        return playlist(id: id)
    }

    /// A row in a playlist. Not a bare `Track`: a playlist may hold the same
    /// track twice, and a list keyed by track id would draw one row where the
    /// user put two — then move and delete the wrong one.
    struct PlaylistEntry: Identifiable, Hashable {
        var position: Int
        var track: Track
        var id: Int { position }
    }

    func entries(in playlist: Playlist) -> [PlaylistEntry] {
        playlist.trackIDs.enumerated().compactMap { position, id in
            tracksByID[id].map { PlaylistEntry(position: position, track: $0) }
        }
    }

    /// What Play and Shuffle work through, in the playlist's own order.
    func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { tracksByID[$0] }
    }

    /// `New Playlist`, then `New Playlist 2` — what the sheet opens with.
    /// Duplicate names are allowed; suggesting one is just rude.
    var suggestedPlaylistName: String {
        let base = "New Playlist"
        let taken = Set(playlists.map(\.name))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Creates the playlist, reloads, and opens it. An empty name falls back
    /// to the suggestion rather than making a playlist called nothing.
    func createPlaylist(named name: String, containing trackIDs: [Track.ID] = []) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = trimmed.isEmpty ? suggestedPlaylistName : trimmed
        do {
            let created = try await store.createPlaylist(named: chosen)
            if !trackIDs.isEmpty {
                try await store.addTracks(trackIDs, to: created.id)
            }
            playlists = try await store.playlists()
            // Straight into the new playlist. Landing on the Playlists shelf
            // instead makes you find the row you just made among the ones you
            // already had.
            show(.playlist(created.id))
        } catch {
            actionError = "Could not create “\(chosen)”: \(error.localizedDescription)"
        }
    }

    /// Appends to the end, and says so — the playlist is usually off-screen
    /// when this runs, so the banner is the only evidence anything happened.
    ///
    /// Takes ids rather than tracks because a drop carries ids; the count in
    /// the message is of the ones the library still recognises, since those
    /// are the ones the store will actually add.
    func addTracks(_ trackIDs: [Track.ID], to playlistID: Playlist.ID) async {
        guard let playlist = playlist(id: playlistID) else { return }
        let known = trackIDs.filter { tracksByID[$0] != nil }
        guard !known.isEmpty else { return }

        guard await edit(playlist, failing: "add to", {
            try await store.addTracks(known, to: playlistID)
        }) else { return }
        let count = known.count == 1 ? "1 track" : "\(known.count) tracks"
        notice = "Added \(count) to “\(playlist.name)”"
    }

    func removeFromPlaylist(_ playlist: Playlist, atOffsets offsets: IndexSet) async {
        await edit(playlist, failing: "remove from") {
            try await store.removeTracks(atOffsets: offsets, from: playlist.id)
        }
    }

    func moveInPlaylist(
        _ playlist: Playlist, fromOffsets source: IndexSet, toOffset destination: Int
    ) async {
        await edit(playlist, failing: "reorder") {
            try await store.moveTracks(fromOffsets: source, toOffset: destination,
                                       in: playlist.id)
        }
    }

    /// An empty name is refused rather than applied: a playlist called nothing
    /// is unreachable in a sidebar.
    func renamePlaylist(_ playlist: Playlist, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.name else { return }
        await edit(playlist, failing: "rename") {
            try await store.renamePlaylist(playlist.id, to: trimmed)
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        await edit(playlist, failing: "delete") {
            try await store.deletePlaylist(playlist.id)
        }
        // Standing on the screen of something that no longer exists shows the
        // dead end in `RootView`; going back is what the user meant.
        if screen == .playlist(playlist.id) {
            show(.library)
            tab = .playlists
        }
    }

    /// Every playlist edit is the same three steps: write, re-read, or report
    /// what went wrong by name. `failing` completes "Could not … “Late Desk”".
    /// Returns whether the write landed, so a caller with something more to
    /// say does not have to infer it from an error field that may be holding
    /// an older failure.
    @discardableResult
    private func edit(
        _ playlist: Playlist, failing verb: String, _ write: () async throws -> Void
    ) async -> Bool {
        do {
            try await write()
            playlists = try await store.playlists()
            return true
        } catch {
            actionError = "Could not \(verb) “\(playlist.name)”: "
                + error.localizedDescription
            return false
        }
    }

    // MARK: Derived counts

    var trackCount: Int { allTracks.count }

    /// The mono figure beside the screen title.
    var screenCount: String {
        switch tab {
        case .artists: "\(artists.count) ARTISTS"
        case .albums: "\(albums.count) ALBUMS"
        case .playlists: "\(playlists.count) PLAYLISTS"
        }
    }

    var librarySummary: String {
        let tracks = NumberFormatter.localizedString(
            from: NSNumber(value: trackCount), number: .decimal)
        return "\(tracks) tracks · \(DurationFormat.bytes(librarySize))"
    }

    // MARK: Search results

    struct SearchResults {
        var topHit: Album?
        var artists: [Artist]
        var albums: [Album]
        var tracks: [Track]

        var isEmpty: Bool {
            topHit == nil && artists.isEmpty && albums.isEmpty && tracks.isEmpty
        }
    }

    /// Substring matching over what is already in memory. The real store does
    /// this with FTS5; the shape of the answer is the same either way, so the
    /// view does not change when that lands.
    var searchResults: SearchResults {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return SearchResults(topHit: nil, artists: [], albums: [], tracks: [])
        }

        let matchedAlbums = albums.filter { $0.title.lowercased().contains(needle) }
        let matchedArtists = artists.filter { $0.name.lowercased().contains(needle) }
        let matchedTracks = allTracks.filter {
            $0.title.lowercased().contains(needle)
                || ($0.composer?.lowercased().contains(needle) ?? false)
        }

        // Prefer an album whose title starts with the query — typing "slow ho"
        // should surface the record, not a track buried in another one.
        let topHit = matchedAlbums.first { $0.title.lowercased().hasPrefix(needle) }
            ?? matchedAlbums.first

        return SearchResults(
            topHit: topHit,
            artists: Array(matchedArtists.prefix(3)),
            albums: Array(matchedAlbums.filter { $0.key != topHit?.key }.prefix(3)),
            tracks: Array(matchedTracks.prefix(3))
        )
    }
}
