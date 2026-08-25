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

    /// How the Artist and Albums screens order what they show — see #69.
    enum LibrarySort: String, CaseIterable, Identifiable {
        case alphabetical, recentlyAdded

        var id: String { rawValue }

        /// What the dropdown and its menu rows say. Kept separate from
        /// `rawValue`, which is what gets persisted — a wording change here
        /// should not touch a value already written to `UserDefaults`.
        var label: String {
            switch self {
            case .alphabetical: "A-Z"
            case .recentlyAdded: "Recently Added"
            }
        }
    }

    // MARK: Navigation

    private(set) var screen: Screen = .library
    var tab: Tab = .artists {
        didSet { settings.set(tab.rawValue, forKey: .tab) }
    }
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
        didSet {
            if !searchText.isEmpty { isSearching = true }
            scheduleSearch()
        }
    }
    var isSearching = false

    func endSearch() {
        isSearching = false
        searchText = ""
    }

    // MARK: Album grid zoom

    /// 0…1. The design's zoom slider; drives the grid's minimum column width.
    var gridZoom: Double = 0.4 {
        didSet { settings.set(gridZoom, forKey: .gridZoom) }
    }

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
    /// An artist has no `dateAdded` of its own — it is an aggregate the store
    /// hands back, not a row with tracks attached — so "recently added" is the
    /// latest addition among everything credited to them, computed once here
    /// rather than re-scanning `allTracks` on every sort.
    private var artistDateAdded: [String: Date] = [:]

    var artistSort: LibrarySort = .alphabetical {
        didSet {
            guard oldValue != artistSort else { return }
            settings.set(artistSort.rawValue, forKey: .artistSort)
            sortArtists()
        }
    }
    var albumSort: LibrarySort = .alphabetical {
        didSet {
            guard oldValue != albumSort else { return }
            settings.set(albumSort.rawValue, forKey: .albumSort)
            sortAlbums()
        }
    }
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
    private let settings: any SettingsStore

    /// Set by the composition root. `AppModel` only holds the store protocol
    /// and has no reach into `LibraryScanner`/`DiskArtworkStore`, but a track
    /// leaving the library outright can orphan its cover — the same gap #40
    /// closed for a track leaving because its file did.
    var pruneArtwork: (() async -> Void)?

    init(store: any LibraryStore, settings: any SettingsStore = InMemorySettingsStore()) {
        self.store = store
        self.settings = settings
        if let raw = settings.string(forKey: .tab), let restored = Tab(rawValue: raw) {
            tab = restored
        }
        if let zoom = settings.double(forKey: .gridZoom) {
            gridZoom = zoom
        }
        if let raw = settings.string(forKey: .artistSort), let restored = LibrarySort(rawValue: raw) {
            artistSort = restored
        }
        if let raw = settings.string(forKey: .albumSort), let restored = LibrarySort(rawValue: raw) {
            albumSort = restored
        }
        recentSearches = Self.decode(settings.string(forKey: .recentSearches))
        recentlyPlayedIDs = Self.decode(settings.string(forKey: .recentlyPlayed)).compactMap(UUID.init)
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
            artistDateAdded = Dictionary(grouping: allTracks, by: \.albumArtist)
                .mapValues { tracks in tracks.map(\.dateAdded).max() ?? .distantPast }
            tracksByID = Dictionary(allTracks.map { ($0.id, $0) }) { first, _ in first }
            // A track removed from the library should not sit in this list
            // forever, wasting one of its five slots on something
            // `recentlyPlayed` will never resolve again.
            recentlyPlayedIDs.removeAll { tracksByID[$0] == nil }
            sortArtists()
            sortAlbums()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Re-sorts in place rather than exposing a computed property, so the
    /// grids' own identity-based diffing (`onChange(of: albums.map(\.id))`,
    /// keyboard focus by index) sees one array update instead of a new one
    /// on every read.
    private func sortArtists() {
        switch artistSort {
        case .alphabetical:
            artists.sort {
                Artist.stripArticle($0.name).localizedStandardCompare(Artist.stripArticle($1.name))
                    == .orderedAscending
            }
        case .recentlyAdded:
            artists.sort {
                artistDateAdded[$0.name, default: .distantPast]
                    > artistDateAdded[$1.name, default: .distantPast]
            }
        }
    }

    private func sortAlbums() {
        switch albumSort {
        case .alphabetical:
            albums.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentlyAdded:
            albums.sort { $0.dateAdded > $1.dateAdded }
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
    /// The tracks the confirmation dialog is asking about — one track from a
    /// context menu, or a whole album's worth. Removing from the library is
    /// the one track action that cannot be undone, same as deleting a
    /// playlist.
    var tracksPendingRemoval: [Track]?
    /// Non-nil while the Get Info sheet is up.
    var infoTrack: Track?

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
        /// A track id plus how many earlier copies of it precede this one in
        /// the playlist. For a track with no duplicates this is stable across
        /// any reorder; `position` alone was not — as a plain index it reads
        /// `0, 1, 2, …` before and after every move, so a drag diffed against
        /// itself and looked like nothing had happened. See #25.
        struct EntryID: Hashable, Codable {
            var trackID: Track.ID
            var occurrence: Int
        }

        var position: Int
        var track: Track
        var id: EntryID
    }

    func entries(in playlist: Playlist) -> [PlaylistEntry] {
        var occurrences: [Track.ID: Int] = [:]
        return playlist.trackIDs.enumerated().compactMap { position, id in
            guard let track = tracksByID[id] else { return nil }
            let occurrence = occurrences[id, default: 0]
            occurrences[id] = occurrence + 1
            return PlaylistEntry(position: position, track: track,
                                  id: .init(trackID: id, occurrence: occurrence))
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

    // MARK: Removing from the library

    /// The track (or every track in an album) leaves the library outright,
    /// not just the screen it was removed from — cascading out of every
    /// playlist through the store's own foreign key. The file on disk is
    /// never touched.
    func removeFromLibrary(_ tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        do {
            try await store.remove(trackIDs: tracks.map(\.id))
            await load()
            await pruneArtwork?()
            let count = tracks.count == 1 ? "1 track" : "\(tracks.count) tracks"
            notice = "Removed \(count) from your library"
        } catch {
            actionError = "Could not remove from your library: "
                + error.localizedDescription
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

        static let empty = SearchResults(topHit: nil, artists: [], albums: [], tracks: [])

        var isEmpty: Bool {
            topHit == nil && artists.isEmpty && albums.isEmpty && tracks.isEmpty
        }
    }

    /// What the popover shows. Filled in asynchronously by `runSearch`, since
    /// the store answers this with FTS5 now rather than an in-memory scan —
    /// see `scheduleSearch`.
    private(set) var searchResults = SearchResults.empty
    private var searchTask: Task<Void, Never>?

    /// True while a query is debouncing or running for the current
    /// `searchText`. Lets the popover tell "no results yet" apart from
    /// "genuinely found nothing" — without it, the first keystroke of a
    /// fresh search flashes "No results" for the length of the debounce,
    /// before the query it hasn't run yet has had a chance to say otherwise.
    /// See #72.
    private(set) var isSearchPending = false

    /// Debounced so a fast typist fires one query, not one per keystroke, and
    /// cancelled on every call so a stale query can never land after a newer
    /// one and flash outdated results.
    private func scheduleSearch() {
        searchTask?.cancel()
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            searchResults = .empty
            isSearchPending = false
            return
        }
        isSearchPending = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.runSearch(needle)
        }
    }

    // MARK: Recent activity

    /// Capped separately from the popover's own `prefix` calls elsewhere —
    /// this is the storage limit, not a display detail. See #72.
    private static let recentSearchesLimit = 5
    private static let recentlyPlayedLimit = 5

    /// Most-recent first. Filled in by `commitCurrentSearch`, never by every
    /// keystroke — `searchText` already drives the live query.
    private(set) var recentSearches: [String] = []

    /// Saves the current query as a recent search: most-recent first,
    /// de-duplicated case-insensitively so searching "beatles" twice doesn't
    /// produce two rows. Call on submit or on picking a result — every
    /// keystroke would fill the history with partial strings.
    func commitCurrentSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > Self.recentSearchesLimit {
            recentSearches.removeLast(recentSearches.count - Self.recentSearchesLimit)
        }
        settings.set(Self.encode(recentSearches), forKey: .recentSearches)
    }

    /// Ids only — the tracks themselves come from `tracksByID`, so a track
    /// that leaves the library drops out of `recentlyPlayed` without this
    /// list needing to be told.
    private var recentlyPlayedIDs: [Track.ID] = []

    /// What the popover shows before anything has been typed. Resolved
    /// against the live library on every read rather than cached, so a
    /// removed track never shows up and a rescan never goes stale.
    var recentlyPlayed: [Track] { recentlyPlayedIDs.compactMap { tracksByID[$0] } }

    /// Wired to `PlaybackController.onTrackStarted` by the composition root —
    /// called once a track actually starts, not when it's merely queued. See
    /// #72.
    func recordPlayed(_ track: Track) {
        recentlyPlayedIDs.removeAll { $0 == track.id }
        recentlyPlayedIDs.insert(track.id, at: 0)
        if recentlyPlayedIDs.count > Self.recentlyPlayedLimit {
            recentlyPlayedIDs.removeLast(recentlyPlayedIDs.count - Self.recentlyPlayedLimit)
        }
        settings.set(Self.encode(recentlyPlayedIDs.map(\.uuidString)), forKey: .recentlyPlayed)
    }

    private static func encode(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        return (try? JSONEncoder().encode(values)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decode(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// FTS5 is token-prefix matching, not substring — searching "hours" no
    /// longer finds "Slow Hours" the way the in-memory scan did, but it folds
    /// diacritics the scan never did ("Halvard As" now finds "Halvard Ås").
    ///
    /// Albums and artists are derived from the track results rather than
    /// queried separately: `tracks(matching:)` already matches against title,
    /// artist, albumArtist, albumTitle and composer, so any album or artist
    /// with a hit anywhere in that set has already surfaced a track here.
    private func runSearch(_ needle: String) async {
        let matchedTracks = try? await store.tracks(matching: needle)
        // Cancelled means a newer keystroke has already scheduled the query
        // that will actually decide `isSearchPending` — leaving it alone
        // here is what keeps that one, not this stale one, in charge of it.
        guard !Task.isCancelled else { return }
        defer { isSearchPending = false }
        guard let matchedTracks else { return }

        var seenAlbumKeys = Set<Album.Key>()
        let matchedAlbums = matchedTracks.compactMap { track -> Album? in
            guard seenAlbumKeys.insert(track.albumKey).inserted else { return nil }
            return album(for: track.albumKey)
        }

        var seenArtistNames = Set<String>()
        let matchedArtists = matchedTracks.compactMap { track -> Artist? in
            guard seenArtistNames.insert(track.albumArtist).inserted else { return nil }
            return artist(named: track.albumArtist)
        }

        // Prefer an album whose title starts with the query — typing "slow ho"
        // should surface the record, not a track buried in another one.
        let lowercasedNeedle = needle.lowercased()
        let topHit = matchedAlbums.first { $0.title.lowercased().hasPrefix(lowercasedNeedle) }
            ?? matchedAlbums.first

        searchResults = SearchResults(
            topHit: topHit,
            artists: Array(matchedArtists.prefix(3)),
            albums: Array(matchedAlbums.filter { $0.key != topHit?.key }.prefix(3)),
            tracks: Array(matchedTracks.prefix(3))
        )
    }
}
