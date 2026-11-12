import Foundation
import ImageIO
import Observation
import CadenceCore
import CadenceLibrary

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
        /// Every album in one genre, by `Genre.id` — the folded tag, so
        /// `Rock` and `rock` are one screen.
        case genre(String)
        /// By id, never by name: two playlists may share one.
        case playlist(Playlist.ID)
        /// One catalog's albums, by id for the same reason.
        case catalog(Catalog.ID)
        /// Every liked track, newest first — the smart playlist the heart on
        /// a track row fills.
        case likedSongs
        /// Preferences, as a full page inside the window rather than the
        /// separate `Settings` window it started as. Reached from the title
        /// bar's gear or ⌘, and left with Back.
        case settings
    }

    enum Tab: String, CaseIterable, Identifiable {
        case home = "Home"
        case artists = "Artists"
        case albums = "Albums"
        case genres = "Genres"
        case playlists = "Playlists"
        case catalogs = "Catalogs"
        case memories = "Memories"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: "house"
            case .artists: "person"
            case .albums: "circle.circle"
            case .genres: "tag"
            case .playlists: "music.note.list"
            case .catalogs: "books.vertical"
            case .memories: "text.bubble"
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

        /// The Playlists grid's wording: a playlist is made and then edited, so
        /// "added" would only ever mean when it was created.
        var playlistLabel: String {
            switch self {
            case .alphabetical: "A-Z"
            case .recentlyAdded: "Recently Updated"
            }
        }
    }

    /// How an artist page shows their albums. `list` stacks each record with
    /// its full tracklist; `grid` is the cover grid the Albums tab uses.
    enum ArtistAlbumLayout: String, CaseIterable, Identifiable {
        case list, grid

        var id: String { rawValue }

        /// Separate from `rawValue`, which is what gets persisted.
        var label: String {
            switch self {
            case .list: "List"
            case .grid: "Grid"
            }
        }

        var systemImage: String {
            switch self {
            case .list: "list.bullet"
            case .grid: "square.grid.2x2"
            }
        }

        /// Tooltip and VoiceOver label: says what the view shows, not just
        /// its name.
        var help: String {
            switch self {
            case .list: "List view: each album with its full tracklist"
            case .grid: "Grid view: album covers only"
            }
        }
    }

    // MARK: Navigation

    private(set) var screen: Screen = .library {
        didSet {
            // The grid anchor names an album of the artist it was saved on.
            // Moving to a different artist — a similar-artist link, or Back
            // and Forward between two — must start that discography at the
            // top rather than look for the other artist's record.
            if case .artist(let new) = screen, case .artist(let old) = oldValue, new != old {
                artistAlbumGridScrollAnchor = nil
            }
            // Same for catalogs, whose pages share one anchor.
            if case .catalog(let new) = screen, case .catalog(let old) = oldValue, new != old {
                catalogAlbumGridScrollAnchor = nil
            }
        }
    }
    var tab: Tab = .artists {
        didSet { settings.set(tab.rawValue, forKey: .tab) }
    }
    var isImmersive = false
    /// A stack, so Back from an album reached through search returns to the
    /// search results' screen rather than guessing.
    private var backStack: [Screen] = []
    /// Screens stepped away from with Back, newest last — Forward retraces
    /// them. A fresh `show(_:)` abandons this branch, matching a browser.
    private var forwardStack: [Screen] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The artist scrolled to the top of `ArtistGrid`, so Back from an artist
    /// detail page restores where the grid was rather than snapping to the
    /// top — the grid itself is torn down and recreated on every navigation.
    var artistGridScrollAnchor: String?

    /// Same idea, for `AlbumGrid` — reused for the Library "Albums" tab and,
    /// with the grid layout chosen, one artist's discography inside
    /// `ArtistDetailView`, so each needs its own anchor. Sharing one would
    /// restore the wrong grid's scroll position after a detour through the
    /// other.
    var libraryAlbumGridScrollAnchor: Album.Key?
    var artistAlbumGridScrollAnchor: Album.Key?

    /// The genre scrolled to the top of the Genres grid, and the album at the
    /// top of one genre's grid layout — separate anchors for the same reason
    /// as the two above.
    var genreGridScrollAnchor: String?
    /// The playlist at the top of the Playlists grid.
    var playlistGridScrollAnchor: Playlist.ID?
    var genreAlbumGridScrollAnchor: Album.Key?
    /// The catalog at the top of the Catalogs grid, and the album at the top
    /// of one catalog's grid layout.
    var catalogGridScrollAnchor: Catalog.ID?
    /// The memory at the top of the Memories grid.
    var memoryGridScrollAnchor: Memory.ID?
    var catalogAlbumGridScrollAnchor: Album.Key?

    func show(_ screen: Screen) {
        // The immersive view covers the whole window, so navigating anywhere —
        // search is the way in from there — has to leave it, or the new screen
        // loads out of sight. Before the guard: picking the screen already
        // underneath still needs to surface it.
        isImmersive = false
        guard screen != self.screen else { return }
        backStack.append(self.screen)
        forwardStack.removeAll()
        self.screen = screen
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(screen)
        screen = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(screen)
        screen = next
    }

    // MARK: Search

    var searchText = "" {
        didSet {
            // `TextField`'s binding reassigns the same string when Return
            // ends its editing session — after `SearchModal`'s own key
            // monitor has already set `searchHighlightedIndex` for that same
            // keypress. Reacting to that reassignment as if the query had
            // changed cleared the highlight out from under `onSubmit`, which
            // reads it a moment later — see #74.
            guard searchText != oldValue else { return }
            if !searchText.isEmpty { isSearching = true }
            // A fresh query means a fresh list — whatever was highlighted
            // before almost certainly isn't the same item any more.
            searchHighlightedIndex = nil
            scheduleSearch()
        }
    }
    var isSearching = false

    /// Arrow-key position in whichever section of `SearchModal` is showing,
    /// in the flat order `SearchModal.activate(_:)` walks. `nil` means
    /// nothing has been explicitly navigated to yet —
    /// `searchEffectiveHighlight` is what actually renders and responds to
    /// Return, defaulting that to the first row — issue #74.
    var searchHighlightedIndex: Int?

    /// How many rows `SearchModal` currently shows, in the same flat order
    /// `SearchModal.activate(_:)` walks: recently played then recent
    /// searches before any text, or top hit then artists then albums then
    /// playlists then tracks once there's a query. Keep in sync with `SearchModal`'s
    /// `suggestions` and `results` if either changes its grouping.
    var searchNavigableCount: Int {
        if searchText.isEmpty {
            return recentlyPlayed.count + recentSearches.count
        }
        return (searchResults.topHit != nil ? 1 : 0) + searchResults.artists.count
            + searchResults.albums.count + searchResults.playlists.count
            + searchResults.catalogs.count
            + searchResults.tracks.count
    }

    /// `searchHighlightedIndex` clamped to the current list, defaulting to
    /// the first row so Return picks something the moment a popover with
    /// results appears — Spotlight's convention, not just this app's.
    var searchEffectiveHighlight: Int? {
        if let searchHighlightedIndex, searchHighlightedIndex < searchNavigableCount {
            return searchHighlightedIndex
        }
        return searchNavigableCount > 0 ? 0 : nil
    }

    /// Moves `searchHighlightedIndex` for an Up/Down arrow press. Lives here,
    /// not as an `.onMoveCommand` on `SearchModal`: the search field's own
    /// text-editing responder answers `moveUp:`/`moveDown:` before SwiftUI's
    /// key-handling would ever see the event — the same conflict
    /// `LibraryView` has with `ScrollView`, except nothing further up the
    /// responder chain can intercept it here. `SearchModal` answers instead
    /// with a local `NSEvent` key monitor, which needs a plain reference type
    /// to call into rather than a `View` struct's own `@State` — see #74.
    func moveSearchHighlight(_ direction: GridNavigation.Direction) {
        guard direction == .up || direction == .down else { return }
        searchHighlightedIndex = GridNavigation.move(from: searchEffectiveHighlight,
                                                      by: direction,
                                                      count: searchNavigableCount, columns: 1)
    }

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
    private(set) var playlistFolders: [PlaylistFolder] = []
    private(set) var allTracks: [Track] = []
    private(set) var librarySize: Int64 = 0
    /// One cover per artist, chosen once at load. Asking for it per card meant
    /// scanning every album in the library on each row the grid drew.
    private var artistArtwork: [String: Artwork.ID] = [:]
    /// Artist name → the image the user set for them, which wins over
    /// `artistArtwork`'s first-album-cover default. Loaded in `load()`.
    private var customArtistImages: [String: Artwork.ID] = [:]
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
    var artistAlbumLayout: ArtistAlbumLayout = .list {
        didSet {
            guard oldValue != artistAlbumLayout else { return }
            settings.set(artistAlbumLayout.rawValue, forKey: .artistAlbumLayout)
        }
    }
    /// Grid by default: a genre can hold hundreds of records, and a stack of
    /// full tracklists is the wrong first look at that many.
    var genreAlbumLayout: ArtistAlbumLayout = .grid {
        didSet {
            guard oldValue != genreAlbumLayout else { return }
            settings.set(genreAlbumLayout.rawValue, forKey: .genreAlbumLayout)
        }
    }
    /// Grid by default, like a genre: a catalog can hold a lot of records.
    var catalogAlbumLayout: ArtistAlbumLayout = .grid {
        didSet {
            guard oldValue != catalogAlbumLayout else { return }
            settings.set(catalogAlbumLayout.rawValue, forKey: .catalogAlbumLayout)
        }
    }
    var albumSort: LibrarySort = .alphabetical {
        didSet {
            guard oldValue != albumSort else { return }
            settings.set(albumSort.rawValue, forKey: .albumSort)
            sortAlbums()
        }
    }
    /// Persisted under its own key. `recentlyAdded` here means recently
    /// *updated* — made, renamed, or changed — see `LibrarySort.playlistLabel`.
    var playlistSort: LibrarySort = .alphabetical {
        didSet {
            guard oldValue != playlistSort else { return }
            settings.set(playlistSort.rawValue, forKey: .playlistSort)
        }
    }

    /// The Playlists grid's order. Separate from `playlists`, which is the
    /// sidebar's order and should not shuffle because the grid was re-sorted.
    var sortedPlaylists: [Playlist] {
        switch playlistSort {
        case .alphabetical:
            return playlists.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .recentlyAdded:
            // Name breaks ties, which also orders playlists that predate the
            // column (all `distantPast`) the way A-Z would.
            return playlists.sorted {
                let (a, b) = ($0.updatedAt ?? .distantPast, $1.updatedAt ?? .distantPast)
                if a != b { return a > b }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Playlists hold track ids; resolving one per row against `allTracks`
    /// would be a linear scan of the whole library for every line on screen.
    private var tracksByID: [Track.ID: Track] = [:]
    /// `album(for:)`/`artist(named:)` back search results — one lookup per
    /// matched track. A linear scan there turns a broad query into millions
    /// of comparisons at library scale; see #85.
    private var albumsByKey: [Album.Key: Album] = [:]
    private var artistsByName: [String: Artist] = [:]
    /// One artist's discography, oldest first — the artist screen's whole
    /// content. Computed once here next to `artistArtwork` rather than
    /// filtering and sorting the full album list on every body pass; see #86.
    /// Independent of `albumSort`, which only reorders the flat `albums` grid.
    private var albumsByArtist: [String: [Album]] = [:]
    /// Genres A–Z, and each one's albums by artist then year. Derived from the
    /// albums in `load()`, like `albumsByArtist`, so the genre screens never
    /// regroup the library while drawing.
    private(set) var genres: [Genre] = []
    private var genresByID: [String: Genre] = [:]
    private var albumsByGenre: [String: [Album]] = [:]
    /// Catalogs A–Z, and the albums each one's rules pick out, in its own
    /// sort. Worked out in `load()` and again whenever a catalog is saved.
    private(set) var catalogs: [Catalog] = []
    private var albumsByCatalog: [Catalog.ID: [Album]] = [:]
    /// What the catalog editor offers as you type or pick a value, per field.
    /// Built from the library at load.
    private var catalogSuggestions: [CatalogRule.Field: [String]] = [:]
    private(set) var isLoading = true
    /// Bumped by every load that succeeds, so caches built from the library —
    /// the similarity index — can tell they are out of date without
    /// comparing the library itself.
    private(set) var libraryGeneration = 0
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

    /// The moment before anything has loaded at all — what the skeleton
    /// screens are for. Distinct from `isLoading` alone: a background
    /// rescan (see `RootView`'s `.task`) also sets that while the library
    /// already has content on screen, and should leave it there rather than
    /// covering it with a skeleton again.
    var isInitialLoading: Bool { isLoading && allTracks.isEmpty }

    let store: any LibraryStore
    private let settings: any SettingsStore
    /// Where a user-chosen artist image's bytes are put — the same
    /// content-addressed store cover art uses. Nil when the real store could
    /// not be opened (see the composition root's catch branch) or in preview
    /// mode, which is what `canEditArtistImage` reports.
    private let artwork: (any ArtworkStore)?

    /// Set by the composition root. `AppModel` only holds the store protocol
    /// and has no reach into `LibraryScanner`/`DiskArtworkStore`, but a track
    /// leaving the library outright can orphan its cover — the same gap #40
    /// closed for a track leaving because its file did.
    var pruneArtwork: (() async -> Void)?

    /// Set by the composition root to `ArtworkLoader.forget`. A custom artist
    /// image records its id the same instant its bytes are written, so a
    /// redraw that raced the write can leave the loader holding a permanent
    /// miss for it — the header then stays on the placeholder until relaunch.
    /// Clearing that entry once the write has settled is what makes the new
    /// image show up straight away.
    var refreshArtwork: ((Artwork.ID) -> Void)?

    /// Set by the composition root to `LibraryImporter.forget`. `AppModel` owns
    /// the library mutation and the reload that a folder removal needs, but the
    /// folder list and its security-scoped bookmarks live on `LibraryImporter`
    /// — so dropping the bookmark is handed over as a closure rather than
    /// widening this type's reach, the same shape as `pruneArtwork`. See #33.
    var forgetFolder: ((URL) -> Void)?

    init(store: any LibraryStore, settings: any SettingsStore = InMemorySettingsStore(),
         artwork: (any ArtworkStore)? = nil,
         memories memoryStore: any MemoryStore = InMemoryMemoryStore()) {
        self.store = store
        self.settings = settings
        self.artwork = artwork
        self.memoryStore = memoryStore
        // "Recents" is the pre-Home name of the first tab.
        if let raw = settings.string(forKey: .tab),
           let restored = Tab(rawValue: raw == "Recents" ? Tab.home.rawValue : raw) {
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
        if let raw = settings.string(forKey: .playlistSort), let restored = LibrarySort(rawValue: raw) {
            playlistSort = restored
        }
        if let raw = settings.string(forKey: .artistAlbumLayout),
           let restored = ArtistAlbumLayout(rawValue: raw) {
            artistAlbumLayout = restored
        }
        if let raw = settings.string(forKey: .genreAlbumLayout),
           let restored = ArtistAlbumLayout(rawValue: raw) {
            genreAlbumLayout = restored
        }
        if let raw = settings.string(forKey: .catalogAlbumLayout),
           let restored = ArtistAlbumLayout(rawValue: raw) {
            catalogAlbumLayout = restored
        }
        recentSearches = Self.decode(settings.string(forKey: .recentSearches))
        recentlyPlayedIDs = Self.decode(settings.string(forKey: .recentlyPlayed)).compactMap(UUID.init)
        recentPlayRefs = Self.decodeRecentPlays(settings.string(forKey: .recentPlays))
        collapsedFolderIDs = Set(Self.decode(settings.string(forKey: .collapsedPlaylistFolders))
            .compactMap(UUID.init))
    }

    func load() async {
        // Whether the skeleton screens are on screen for this call — see
        // `isInitialLoading`. Read before anything below changes `allTracks`.
        let showsSkeleton = isInitialLoading
        let clock = ContinuousClock()
        let start = clock.now

        isLoading = true
        defer { isLoading = false }
        do {
            // Independent reads, fired together so the pool's readers overlap
            // instead of the load serializing one round trip after another.
            async let tracksFetch = store.allTracks()
            async let artistsFetch = store.artists()
            async let playlistsFetch = store.playlists()
            async let foldersFetch = store.playlistFolders()
            async let librarySizeFetch = store.librarySize()
            async let customArtistImagesFetch = store.customArtistImages()
            async let catalogsFetch = store.catalogs()
            async let likedFetch = store.likedTrackIDs()
            async let memoriesFetch = memoryStore.memories()

            allTracks = try await tracksFetch
            albums = Album.grouped(from: allTracks)
            artists = try await artistsFetch
            playlists = try await playlistsFetch
            playlistFolders = try await foldersFetch
            librarySize = try await librarySizeFetch
            artistArtwork = albums.reduce(into: [:]) { result, album in
                guard let artworkID = album.artworkID else { return }
                result[album.albumArtist] = result[album.albumArtist] ?? artworkID
            }
            customArtistImages = try await customArtistImagesFetch
            artistDateAdded = Dictionary(grouping: allTracks, by: \.albumArtist)
                .mapValues { tracks in tracks.map(\.dateAdded).max() ?? .distantPast }
            tracksByID = Dictionary(allTracks.map { ($0.id, $0) }) { first, _ in first }
            albumsByKey = Dictionary(albums.map { ($0.key, $0) }) { first, _ in first }
            artistsByName = Dictionary(artists.map { ($0.name, $0) }) { first, _ in first }
            albumsByArtist = Dictionary(grouping: albums, by: \.albumArtist)
                .mapValues { group in
                    group.sorted {
                        ($0.year ?? 0, $0.title.localizedLowercase)
                            < ($1.year ?? 0, $1.title.localizedLowercase)
                    }
                }
            let grouping = Genre.grouped(from: albums)
            genres = grouping.genres
            genresByID = Dictionary(genres.map { ($0.id, $0) }) { first, _ in first }
            albumsByGenre = grouping.albumsByGenre.mapValues { group in
                group.sorted {
                    let (a, b) = (Artist.stripArticle($0.albumArtist),
                                  Artist.stripArticle($1.albumArtist))
                    let order = a.localizedStandardCompare(b)
                    if order != .orderedSame { return order == .orderedAscending }
                    return ($0.year ?? 0, $0.title.localizedLowercase)
                        < ($1.year ?? 0, $1.title.localizedLowercase)
                }
            }
            catalogSuggestions = Self.catalogSuggestions(albums: albums, artists: artists,
                                                         genres: genres)
            setCatalogs(try await catalogsFetch)
            setLikedTrackIDs(try await likedFetch)
            // Notes are not the library: one that fails to read should not
            // stop the records from showing. Keep what was there instead.
            if let fetched = try? await memoriesFetch { setMemories(fetched) }
            // A track removed from the library should not sit in this list
            // forever, wasting one of its five slots on something
            // `recentlyPlayed` will never resolve again.
            recentlyPlayedIDs.removeAll { tracksByID[$0] == nil }
            // Same for the Recents grid: an album gone with its folder or a
            // deleted playlist should give its slot back rather than linger as
            // a ref that never resolves.
            recentPlayRefs.removeAll { ref in
                switch ref {
                case .album(let key): albumsByKey[key] == nil
                case .playlist(let id): !playlists.contains { $0.id == id }
                }
            }
            sortArtists()
            sortAlbums()
            libraryGeneration += 1
            // A local library reads fast enough that the skeleton can finish
            // and disappear inside a single frame — never actually visible.
            // Padding only the first load out to a minimum is what makes it
            // read as a loading state rather than a flash of nothing; a
            // background rescan already has content on screen and has no
            // skeleton to hold, so it isn't slowed down by this at all.
            if showsSkeleton {
                let minimum = Duration.milliseconds(400)
                let elapsed = clock.now - start
                if elapsed < minimum {
                    try? await Task.sleep(for: minimum - elapsed)
                }
            }
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
        albumsByKey[key]
    }

    /// "Just play something": any album with something to play, avoiding the
    /// one already playing so each pick changes the record — unless the
    /// library holds only that one.
    func randomAlbum(excluding current: Album.Key? = nil) -> Album? {
        let playable = albums.filter { $0.discs.contains { !$0.tracks.isEmpty } }
        let fresh = playable.filter { $0.key != current }
        return (fresh.isEmpty ? playable : fresh).randomElement()
    }

    /// Counts "Just play something" picks, so the title bar's die rolls
    /// whether the pick came from the die itself or from the menu shortcut.
    private(set) var somethingPlayed = 0

    /// Play a random album from track 1. Shared by the title bar's die and
    /// the Playback menu's ⌘J.
    func justPlaySomething(on playback: PlaybackController) {
        guard let album = randomAlbum(excluding: playback.currentTrack?.albumKey) else { return }
        playback.play(album)
        somethingPlayed += 1
    }

    /// An artist has no picture of their own. The user's own choice wins;
    /// failing that, the first cover they released stands in, which is what
    /// every other music app does too.
    func artworkID(forArtist name: String) -> Artwork.ID? {
        customArtistImages[name] ?? artistArtwork[name]
    }

    /// Whether the user has set an image for this artist, as opposed to the
    /// album-cover fallback — what the editor's "Remove" control keys off.
    func hasCustomImage(forArtist name: String) -> Bool {
        customArtistImages[name] != nil
    }

    /// Whether artist images can be edited at all. False when the real artwork
    /// store could not be opened, or in preview mode — the editor's entry point
    /// hides rather than offering a control that cannot land anywhere.
    var canEditArtistImage: Bool { artwork != nil }

    /// The artist whose image editor is open, if any — drives the sheet in
    /// `RootView`.
    var editingArtist: Artist?

    /// Reads `fileURL`, checks it decodes as an image, stores the bytes in the
    /// artwork store and records the artist's override. The previous custom
    /// image, if any, is left for the next prune to sweep — it is no longer
    /// referenced once the row is rewritten.
    func setArtistImage(fromFile fileURL: URL, forArtist name: String) async {
        guard let artwork, let data = readImage(at: fileURL) else { return }
        do {
            let id = try await artwork.store(data)
            try await store.setCustomArtistImage(id, forArtist: name)
            customArtistImages = try await store.customArtistImages()
            await pruneArtwork?()
            // The loader may have already recorded a miss for this id on the
            // redraw that `customArtistImages` just triggered — clear it so the
            // header picks the new image up now rather than on next launch.
            refreshArtwork?(id)
            notice = "Updated the image for “\(name)”"
        } catch {
            actionError = "Could not set the image for “\(name)”: "
                + error.localizedDescription
        }
    }

    /// Drops the artist's override so the album-cover fallback shows again, and
    /// prunes the now-orphaned upload.
    func removeArtistImage(forArtist name: String) async {
        guard hasCustomImage(forArtist: name) else { return }
        do {
            try await store.setCustomArtistImage(nil, forArtist: name)
            customArtistImages = try await store.customArtistImages()
            await pruneArtwork?()
            notice = "Reset the image for “\(name)”"
        } catch {
            actionError = "Could not reset the image for “\(name)”: "
                + error.localizedDescription
        }
    }

    /// The bytes of an image file the user picked, or nil — with the reason in
    /// `actionError` — when it cannot be read or is not an image.
    private func readImage(at fileURL: URL) -> Data? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            actionError = "Could not read that file: \(error.localizedDescription)"
            return nil
        }
        guard Self.isReadableImage(data) else {
            actionError = "“\(fileURL.lastPathComponent)” isn’t an image Cadence can read."
            return nil
        }
        return data
    }

    // MARK: Playlist covers

    /// Whether playlist covers can be set at all — the same artwork store the
    /// artist images need.
    var canEditPlaylistImage: Bool { artwork != nil }

    /// The playlist whose cover editor is open, if any — drives the sheet in
    /// `RootView`.
    var editingPlaylist: Playlist?

    func setPlaylistImage(fromFile fileURL: URL, for playlist: Playlist) async {
        guard let artwork, let data = readImage(at: fileURL) else { return }
        do {
            let id = try await artwork.store(data)
            let saved = await edit(playlist, failing: "set the cover for") {
                try await store.setPlaylistImage(id, forPlaylist: playlist.id)
            }
            guard saved else { return }
            await pruneArtwork?()
            // See `setArtistImage`: clear any miss the loader recorded for the
            // id before its bytes landed.
            refreshArtwork?(id)
            notice = "Updated the cover for “\(playlist.name)”"
        } catch {
            actionError = "Could not set the cover for “\(playlist.name)”: "
                + error.localizedDescription
        }
    }

    /// Back to the tiled album covers; prunes the now-orphaned upload.
    func removePlaylistImage(for playlist: Playlist) async {
        guard playlist.artworkID != nil else { return }
        let saved = await edit(playlist, failing: "reset the cover for") {
            try await store.setPlaylistImage(nil, forPlaylist: playlist.id)
        }
        guard saved else { return }
        await pruneArtwork?()
        notice = "Reset the cover for “\(playlist.name)”"
    }

    /// A cheap gate before handing bytes to the artwork store: ImageIO can name
    /// a type for them and there is at least one frame. Keeps a renamed text
    /// file or a truncated download from becoming an artist's blank avatar.
    private static func isReadableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    func artist(named name: String) -> Artist? {
        artistsByName[name]
    }

    /// Every album credited to one artist, oldest first. Resolved once in
    /// `load()` — the store has the same query, but the whole library is
    /// already in memory and the artist screen should not wait on a round
    /// trip, nor re-filter and re-sort it on every body pass. See #86.
    func albums(byArtist name: String) -> [Album] {
        albumsByArtist[name] ?? []
    }

    func genre(id: String) -> Genre? {
        genresByID[id]
    }

    /// Every album in one genre, by artist then year. Empty for a genre the
    /// library does not have.
    func albums(inGenre id: String) -> [Album] {
        albumsByGenre[id] ?? []
    }

    // MARK: Catalogs

    /// What the catalog editor is open for: a new catalog, or changing the
    /// rules (and name) of one that exists.
    enum CatalogEditing: Identifiable, Hashable {
        case create
        case edit(Catalog)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let catalog): catalog.id.uuidString
            }
        }
    }

    /// Non-nil while the catalog editor sheet is up.
    var editingCatalog: CatalogEditing?
    /// The catalog the confirmation dialog is asking about.
    var catalogPendingDeletion: Catalog?

    func catalog(id: Catalog.ID) -> Catalog? {
        catalogs.first { $0.id == id }
    }

    /// The albums one catalog's rules pick out, in its own sort.
    func albums(inCatalog id: Catalog.ID) -> [Album] {
        albumsByCatalog[id] ?? []
    }

    func coverIDs(forCatalog catalog: Catalog) -> [Artwork.ID] {
        Catalog.covers(of: albums(inCatalog: catalog.id))
    }

    /// The albums a definition would hold, for the editor's live count. Run
    /// against the whole library on each change — a filter over albums
    /// already in memory, cheap next to a keystroke.
    func previewAlbums(for definition: Catalog.Definition) -> [Album] {
        let now = Date()
        return albums.filter { definition.matches($0, now: now) }
    }

    /// Values the editor suggests for a field: labels, artists and genres as
    /// the library spells them, the decades and codecs it has.
    func catalogValues(for field: CatalogRule.Field) -> [String] {
        catalogSuggestions[field] ?? []
    }

    /// `New Catalog`, then `New Catalog 2`.
    var suggestedCatalogName: String {
        let base = "New Catalog"
        let taken = Set(catalogs.map(\.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Creates a catalog, or updates the one being edited, then opens it.
    /// Incomplete rules are dropped on the way in, so what is stored is what
    /// the summary line says.
    func saveCatalog(name: String, definition: Catalog.Definition,
                     editing: CatalogEditing) async {
        var definition = definition
        definition.rules = definition.completeRules
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: Catalog
        switch editing {
        case .create:
            saved = Catalog(name: trimmed.isEmpty ? suggestedCatalogName : trimmed,
                            definition: definition)
        case .edit(let existing):
            var updated = catalog(id: existing.id) ?? existing
            updated.name = trimmed.isEmpty ? updated.name : trimmed
            updated.definition = definition
            updated.updatedAt = Date()
            saved = updated
        }
        guard await writeCatalog(saved, failing: "save") else { return }
        if case .create = editing {
            show(.catalog(saved.id))
        }
    }

    func renameCatalog(_ catalog: Catalog, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var updated = self.catalog(id: catalog.id),
              updated.name != trimmed else { return }
        updated.name = trimmed
        updated.updatedAt = Date()
        await writeCatalog(updated, failing: "rename")
    }

    /// The sort lives in the catalog's own definition, so it is saved with
    /// it rather than kept as an app-wide preference.
    func setSort(_ sort: CatalogSort, forCatalog catalog: Catalog) async {
        guard var updated = self.catalog(id: catalog.id),
              updated.definition.sort != sort else { return }
        updated.definition.sort = sort
        updated.updatedAt = Date()
        await writeCatalog(updated, failing: "sort")
    }

    func deleteCatalog(_ catalog: Catalog) async {
        do {
            try await store.deleteCatalog(catalog.id)
            setCatalogs(try await store.catalogs())
        } catch {
            actionError = "Could not delete “\(catalog.name)”: " + error.localizedDescription
            return
        }
        if screen == .catalog(catalog.id) {
            show(.library)
            tab = .catalogs
        }
    }

    @discardableResult
    private func writeCatalog(_ catalog: Catalog, failing verb: String) async -> Bool {
        do {
            try await store.saveCatalog(catalog)
            setCatalogs(try await store.catalogs())
            return true
        } catch {
            actionError = "Could not \(verb) “\(catalog.name)”: " + error.localizedDescription
            return false
        }
    }

    /// Stores the catalogs A–Z and works out each one's albums.
    private func setCatalogs(_ fetched: [Catalog]) {
        let now = Date()
        catalogs = fetched.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        albumsByCatalog = Dictionary(catalogs.map { catalog in
            (catalog.id, catalog.definition.albums(from: albums, now: now))
        }) { first, _ in first }
    }

    /// Distinct values per field, A–Z. Labels fold like genres do — `ECM`
    /// and `ecm` are one entry, under whichever spelling the library uses
    /// most.
    private static func catalogSuggestions(albums: [Album], artists: [Artist],
                                           genres: [Genre]) -> [CatalogRule.Field: [String]] {
        var labelSpellings: [String: [String: Int]] = [:]
        var decades = Set<Int>()
        var codecs = Set<String>()
        for album in albums {
            if let year = album.year { decades.insert(year / 10 * 10) }
            for track in album.tracks {
                codecs.insert(track.format.codec.name)
                guard let label = track.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let key = Genre.key(for: label) else { continue }
                labelSpellings[key, default: [:]][label, default: 0] += 1
            }
        }
        let labels = labelSpellings.values.compactMap { spellings in
            spellings.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }
        let byName: (String, String) -> Bool = {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return [
            .label: labels.sorted(by: byName),
            .artist: artists.map(\.name).sorted(by: byName),
            .genre: genres.map(\.name),
            .decade: decades.sorted().map(String.init),
            .format: [CatalogRule.FormatChoice.lossless, CatalogRule.FormatChoice.lossy,
                      CatalogRule.FormatChoice.hiRes] + codecs.sorted(by: byName),
        ]
    }

    var currentAlbum: Album? {
        guard case .album(let key) = screen else { return nil }
        return album(for: key)
    }

    // MARK: Memories

    /// Where memories are kept — the library database in the app, memory in
    /// previews and tests.
    private let memoryStore: any MemoryStore

    /// Every memory, newest first.
    private(set) var memories: [Memory] = []
    /// By record, newest first — what an album page and the album of the day
    /// read, without filtering every note on each body pass.
    private var memoriesByAlbum: [Album.Key: [Memory]] = [:]

    /// What the memory editor is open for.
    enum MemoryEditing: Identifiable, Hashable {
        case create(Memory.Subject)
        case edit(Memory)

        var id: String {
            switch self {
            case .create(let subject): "create-\(subject.hashValue)"
            case .edit(let memory): memory.id.uuidString
            }
        }

        var subject: Memory.Subject {
            switch self {
            case .create(let subject): subject
            case .edit(let memory): memory.subject
            }
        }
    }

    /// Non-nil while the memory editor sheet is up.
    var editingMemory: MemoryEditing?

    /// Every note on a record — about it or any song on it — newest first.
    func memories(aboutAlbum key: Album.Key) -> [Memory] {
        memoriesByAlbum[key] ?? []
    }

    /// The notes about one song, newest first.
    func memories(about track: Track) -> [Memory] {
        memories(aboutAlbum: track.albumKey).filter { $0.subject.matches(track) }
    }

    func hasMemory(_ track: Track) -> Bool {
        memories(aboutAlbum: track.albumKey).contains { $0.subject.matches(track) }
    }

    /// The notes Home can bring back: those whose record is in the library,
    /// so the hero has something to open and play.
    var showableMemories: [Memory] {
        memories.filter { albumsByKey[$0.subject.albumKey] != nil }
    }

    /// The song a note is about, found on its record by name — or nil for a
    /// note on the whole record, or a song no longer on it.
    func track(for subject: Memory.Subject) -> Track? {
        guard subject.trackTitle != nil,
              let album = albumsByKey[subject.albumKey] else { return nil }
        return album.tracks.first { subject.matches($0) }
    }

    /// Plays what a note is about: the song, carrying on through the rest of
    /// its record the way clicking its row on the album page would, or the
    /// whole record for a note on the record — or for a song no longer on
    /// it. Nothing, when the record has left the library.
    func play(_ memory: Memory, on playback: PlaybackController) {
        guard let album = albumsByKey[memory.subject.albumKey] else { return }
        if let track = track(for: memory.subject) {
            playback.play(track, in: album.discs.flatMap(\.tracks))
        } else {
            playback.play(album)
        }
    }

    /// Whether `play(_:on:)` has anything to play.
    func canPlay(_ memory: Memory) -> Bool {
        albumsByKey[memory.subject.albumKey] != nil
    }

    /// `“Anhedonia”` for a song, the record's title for a whole record —
    /// the heading a note is shown under.
    func title(of subject: Memory.Subject) -> String {
        switch subject {
        case .album(let key): key.title
        case .track(let title, _, _): "“\(title)”"
        }
    }

    /// Saves a new note, or the changes to one. Emptying a note's text is
    /// the same as deleting it — there is nothing left to keep.
    func saveMemory(text: String, editing: MemoryEditing) async {
        guard let cleaned = Memory.cleaned(text) else {
            if case .edit(let existing) = editing { await deleteMemory(existing) }
            return
        }
        let memory: Memory
        switch editing {
        case .create(let subject):
            memory = Memory(subject: subject, text: cleaned)
        case .edit(let existing):
            guard existing.text != cleaned else { return }
            var updated = existing
            updated.text = cleaned
            updated.updatedAt = Date()
            memory = updated
        }
        do {
            try await memoryStore.saveMemory(memory)
            setMemories(try await memoryStore.memories())
            if case .create = editing {
                notice = "Saved a memory for \(title(of: memory.subject))"
            }
        } catch {
            actionError = "Could not save the memory: " + error.localizedDescription
        }
    }

    func deleteMemory(_ memory: Memory) async {
        do {
            try await memoryStore.deleteMemory(memory.id)
            setMemories(try await memoryStore.memories())
        } catch {
            actionError = "Could not delete the memory: " + error.localizedDescription
        }
    }

    private func setMemories(_ fetched: [Memory]) {
        memories = fetched.sorted(by: Memory.newestFirst)
        memoriesByAlbum = Dictionary(grouping: memories, by: \.subject.albumKey)
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
        /// A folder is named by the same dialog: the question — what should
        /// this be called? — is the same one.
        case createFolder
        case renameFolder(PlaylistFolder)
        /// Catalogs too: renaming one is the same one-field question.
        case renameCatalog(Catalog)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let playlist): playlist.id.uuidString
            case .createFolder: "create-folder"
            case .renameFolder(let folder): "folder-\(folder.id.uuidString)"
            case .renameCatalog(let catalog): "catalog-\(catalog.id.uuidString)"
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
    /// True while the Import Spotify Playlist sheet is up.
    var isImportingSpotifyPlaylist = false
    /// The music folder the Preferences confirmation dialog is asking about.
    /// Removing a folder takes its tracks out of the library with it, which is
    /// not undoable — see #33.
    var folderPendingRemoval: URL?

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

    /// Resolves a bare id against the loaded library — what
    /// `PlaybackController.restoreQueue(resolving:)` calls to turn the ids it
    /// persisted back into real `Track`s. See #42.
    func track(id: Track.ID) -> Track? { tracksByID[id] }

    /// What a playlist's tile shows: its own cover if the user chose one, else up
    /// to four different covers from its tracks —
    /// see `CoverMosaic`. Lazy, so a long playlist stops at the fourth cover
    /// instead of resolving every id on every body pass. See #86.
    func coverIDs(forPlaylist playlist: Playlist) -> [Artwork.ID] {
        // The user's own cover replaces the tiles outright.
        if let chosen = playlist.artworkID { return [chosen] }
        return Artwork.firstDistinct(
            playlist.trackIDs.lazy.compactMap { self.tracksByID[$0]?.artworkID }, limit: 4)
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

    /// The last step of a Spotify import: a playlist of whatever the library
    /// had, and a notice that says how much that was. A playlist with nothing
    /// matched is not created — an empty one would only need deleting.
    func importPlaylist(named name: String, matched: [Track], total: Int) async {
        guard !matched.isEmpty else {
            actionError = total == 0
                ? "“\(name)” has no tracks to import."
                : "None of the \(total) tracks in “\(name)” are in your library."
            return
        }
        actionError = nil
        await createPlaylist(named: name, containing: matched.map(\.id))
        guard actionError == nil else { return }
        let skipped = total - matched.count
        notice = skipped == 0
            ? "Imported all \(total) tracks from “\(name)”"
            : "Imported \(matched.count) of \(total) tracks from “\(name)” — "
                + "\(skipped) not in your library"
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

    // MARK: Liked songs

    /// What the sidebar row and its screen are called.
    nonisolated static let likedSongsName = "Liked Songs"

    /// Newest first, as the store keeps them. Ids only, resolved through
    /// `tracksByID`, so a track that leaves the library drops out without
    /// this list needing to be told — the store's cascade forgets it too.
    private(set) var likedTrackIDs: [Track.ID] = []
    /// The same ids as a set, for the heart on every row: asking an array
    /// would be a linear scan per row drawn.
    private var likedIDSet: Set<Track.ID> = []

    func isLiked(_ track: Track) -> Bool { likedIDSet.contains(track.id) }

    /// What Liked Songs lists and plays, newest first.
    var likedTracks: [Track] { likedTrackIDs.compactMap { tracksByID[$0] } }

    var likedSongsSummary: String {
        let count = likedTracks.count
        return count == 1 ? "1 track" : "\(count) tracks"
    }

    /// Flips one track's heart.
    func toggleLike(_ track: Track, announce: Bool = false) async {
        await setLiked(!isLiked(track), [track], announce: announce)
    }

    /// Likes or unlikes tracks. The heart changes at once rather than after
    /// the write, so a click never looks ignored; if the write fails, the
    /// list goes back to what the store holds and the banner says why.
    ///
    /// `announce` is for a menu or a shortcut, where the heart that changed
    /// may be nowhere on screen — the same reason adding to a playlist says
    /// so. A click on a heart is its own evidence.
    func setLiked(_ liked: Bool, _ tracks: [Track], announce: Bool = false) async {
        let ids = tracks.map(\.id).filter { tracksByID[$0] != nil && likedIDSet.contains($0) != liked }
        guard !ids.isEmpty else { return }
        if liked {
            var seen = Set<Track.ID>()
            setLikedTrackIDs(ids.filter { seen.insert($0).inserted } + likedTrackIDs)
        } else {
            let doomed = Set(ids)
            setLikedTrackIDs(likedTrackIDs.filter { !doomed.contains($0) })
        }
        do {
            try await store.setLiked(liked, trackIDs: ids)
            guard announce else { return }
            let subject = tracks.count == 1 ? "“\(tracks[0].title)”"
                : "\(ids.count) tracks"
            notice = liked ? "Added \(subject) to \(Self.likedSongsName)"
                : "Removed \(subject) from \(Self.likedSongsName)"
        } catch {
            actionError = "Could not \(liked ? "like" : "unlike") "
                + (tracks.count == 1 ? "“\(tracks[0].title)”" : "those tracks")
                + ": " + error.localizedDescription
            if let stored = try? await store.likedTrackIDs() {
                setLikedTrackIDs(stored)
            }
        }
    }

    private func setLikedTrackIDs(_ ids: [Track.ID]) {
        likedTrackIDs = ids
        likedIDSet = Set(ids)
    }

    // MARK: Playlist folders

    /// The sidebar folders the user has closed. Stored as the collapsed set,
    /// not the expanded one, so a folder opens until someone closes it — a
    /// new folder that appears shut would hide the playlist just dropped in.
    private(set) var collapsedFolderIDs: Set<PlaylistFolder.ID> = []

    func playlistFolder(id: PlaylistFolder.ID) -> PlaylistFolder? {
        playlistFolders.first { $0.id == id }
    }

    /// The playlists filed under one folder, or with `nil` the ones at the top
    /// level, in the sidebar's own order. A playlist whose folder is not in
    /// `playlistFolders` counts as top level: hiding it under a folder the
    /// sidebar cannot draw would lose it from view entirely.
    func playlists(in folderID: PlaylistFolder.ID?) -> [Playlist] {
        guard let folderID else {
            let known = Set(playlistFolders.map(\.id))
            return playlists.filter { $0.folderID.map { !known.contains($0) } ?? true }
        }
        return playlists.filter { $0.folderID == folderID }
    }

    func isExpanded(_ folder: PlaylistFolder) -> Bool {
        !collapsedFolderIDs.contains(folder.id)
    }

    func setExpanded(_ expanded: Bool, _ folder: PlaylistFolder) {
        if expanded {
            collapsedFolderIDs.remove(folder.id)
        } else {
            collapsedFolderIDs.insert(folder.id)
        }
        persistCollapsedFolders()
    }

    /// `New Folder`, then `New Folder 2` — the same courtesy as playlists.
    var suggestedFolderName: String {
        let base = "New Folder"
        let taken = Set(playlistFolders.map(\.name))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Unlike a new playlist, a new folder does not open anything: it has no
    /// screen of its own, and the sidebar row it adds is already where the
    /// user is looking.
    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = trimmed.isEmpty ? suggestedFolderName : trimmed
        do {
            try await store.createPlaylistFolder(named: chosen)
            playlistFolders = try await store.playlistFolders()
        } catch {
            actionError = "Could not create “\(chosen)”: \(error.localizedDescription)"
        }
    }

    /// Same rule as playlists: an empty name is refused, not applied.
    func renameFolder(_ folder: PlaylistFolder, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != folder.name else { return }
        await editFolders(failing: "rename “\(folder.name)”") {
            try await store.renamePlaylistFolder(folder.id, to: trimmed)
        }
    }

    /// The folder goes; its playlists stay, back at the top level. That is
    /// why this asks no confirmation where deleting a playlist does — nothing
    /// is lost that a drag cannot put back.
    func deleteFolder(_ folder: PlaylistFolder) async {
        guard await editFolders(failing: "delete “\(folder.name)”", {
            try await store.deletePlaylistFolder(folder.id)
        }) else { return }
        if collapsedFolderIDs.remove(folder.id) != nil { persistCollapsedFolders() }
    }

    /// Files a playlist under `folderID`, or at the top level with `nil`.
    /// Dropping a playlist where it already is does nothing, so a drag that
    /// ends where it began does not cost a write and a reload.
    func movePlaylist(_ playlistID: Playlist.ID, toFolder folderID: PlaylistFolder.ID?) async {
        guard let playlist = playlist(id: playlistID), playlist.folderID != folderID else { return }
        if let folderID, playlistFolder(id: folderID) == nil { return }
        await edit(playlist, failing: "move") {
            try await store.movePlaylist(playlistID, toFolder: folderID)
        }
        // A playlist dropped onto a closed folder would otherwise disappear
        // under the pointer; opening it shows where it went.
        if let folderID, collapsedFolderIDs.remove(folderID) != nil {
            persistCollapsedFolders()
        }
    }

    // MARK: Sidebar drops

    /// What can land on the sidebar: tracks from a list, or a playlist
    /// dragged out of the sidebar itself.
    enum SidebarDrop {
        case tracks([Track.ID])
        case playlist(Playlist.ID)
    }

    /// Where in the sidebar it landed.
    enum SidebarDropTarget {
        case playlist(Playlist)
        case folder(PlaylistFolder.ID)
        /// The Playlists heading and the empty space below the list.
        case topLevel
    }

    /// Every sidebar drop goes through here, whichever view it landed on, so
    /// the rules live in one place and can be tested without a drag.
    ///
    /// A playlist dropped on another playlist lands in that playlist's
    /// folder, or at the top level if it has none: the row stands for the
    /// place it sits, not for itself. That is also one way back out of a
    /// folder. Returns whether the drop is taken, for SwiftUI's drop handler,
    /// which has to answer before the write is done.
    @discardableResult
    func handleDrop(_ drop: SidebarDrop, on target: SidebarDropTarget) -> Bool {
        guard accepts(drop, on: target) else { return false }
        Task { await performDrop(drop, on: target) }
        return true
    }

    /// Whether `target` takes `drop` at all. Tracks have no home in a folder
    /// or at the top level, and a playlist dropped on itself goes nowhere.
    func accepts(_ drop: SidebarDrop, on target: SidebarDropTarget) -> Bool {
        switch (drop, target) {
        case (.tracks(let ids), .playlist): !ids.isEmpty
        case (.tracks, _): false
        case (.playlist(let id), .playlist(let sibling)): id != sibling.id
        case (.playlist, .folder), (.playlist, .topLevel): true
        }
    }

    /// The write behind an accepted drop.
    func performDrop(_ drop: SidebarDrop, on target: SidebarDropTarget) async {
        switch (drop, target) {
        case (.tracks(let ids), .playlist(let playlist)):
            await addTracks(ids, to: playlist.id)
        case (.tracks, _):
            break
        case (.playlist(let id), .playlist(let sibling)):
            await movePlaylist(id, toFolder: sibling.folderID)
        case (.playlist(let id), .folder(let folderID)):
            await movePlaylist(id, toFolder: folderID)
        case (.playlist(let id), .topLevel):
            await movePlaylist(id, toFolder: nil)
        }
    }

    /// Folder edits re-read playlists as well as folders: deleting one moves
    /// its playlists, and the sidebar draws both from the same pass.
    @discardableResult
    private func editFolders(
        failing what: String, _ write: () async throws -> Void
    ) async -> Bool {
        do {
            try await write()
            playlistFolders = try await store.playlistFolders()
            playlists = try await store.playlists()
            return true
        } catch {
            actionError = "Could not \(what): " + error.localizedDescription
            return false
        }
    }

    private func persistCollapsedFolders() {
        settings.set(Self.encode(collapsedFolderIDs.map(\.uuidString).sorted()),
                     forKey: .collapsedPlaylistFolders)
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

    /// The tracks the library holds from under `folder` — what a folder removal
    /// would take with it, and what the confirmation dialog counts. Matched by
    /// path component, the same way the scanner decides a file belongs to the
    /// folder it is walking.
    func tracks(under folder: URL) -> [Track] {
        allTracks.filter { LibraryScanner.isDescendant($0.url, of: folder) }
    }

    /// Drops a music folder: its bookmark is released (via `forgetFolder`, so it
    /// is not resolved or rescanned on the next launch) and every track the
    /// library held from inside it leaves outright, cascading out of playlists
    /// through the store's own foreign key. Files on disk are never touched.
    ///
    /// The store write comes first: if it fails the folder stays on the list to
    /// try again, rather than a folder that is gone from the list while its now
    /// unreachable tracks linger.
    func removeFolder(_ folder: URL) async {
        let doomed = tracks(under: folder)
        do {
            if !doomed.isEmpty {
                try await store.remove(trackIDs: doomed.map(\.id))
            }
            forgetFolder?(folder)
            await load()
            await pruneArtwork?()
            let name = folder.lastPathComponent
            notice = doomed.isEmpty
                ? "Removed “\(name)” from your library"
                : "Removed “\(name)” and \(doomed.count == 1 ? "1 track" : "\(doomed.count) tracks")"
        } catch {
            actionError = "Could not remove “\(folder.lastPathComponent)”: "
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
        case .home: ""
        case .artists: "\(artists.count) ARTISTS"
        case .albums: "\(albums.count) ALBUMS"
        case .genres: "\(genres.count) GENRES"
        case .playlists: "\(playlists.count) PLAYLISTS"
        case .catalogs: catalogs.count == 1 ? "1 CATALOG" : "\(catalogs.count) CATALOGS"
        case .memories: memories.count == 1 ? "1 MEMORY" : "\(memories.count) MEMORIES"
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
        var playlists: [Playlist] = []
        var catalogs: [Catalog] = []
        var tracks: [Track]

        static let empty = SearchResults(topHit: nil, artists: [], albums: [], tracks: [])

        var isEmpty: Bool {
            topHit == nil && artists.isEmpty && albums.isEmpty && playlists.isEmpty
                && catalogs.isEmpty && tracks.isEmpty
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
    /// The Recents grid's history. Longer than the popover's five: this is a
    /// browsing surface of its own, not a suggestion strip.
    private static let recentPlaysLimit = 30

    // MARK: Recently played collections

    /// A collection the user has played — the unit the Recents grid is built
    /// from. Stored as a reference, never a resolved value, so a rescan that
    /// drops an album or a deleted playlist falls out of the list without it
    /// needing to be told, the same way `recentlyPlayedIDs` handles tracks.
    enum RecentPlay: Hashable, Codable {
        case album(Album.Key)
        case playlist(Playlist.ID)
    }

    /// A resolved Recents entry, ready for a card. Artists are deliberately
    /// absent — the Recents grid shows records and playlists only.
    enum RecentlyPlayed: Identifiable {
        case album(Album)
        case playlist(Playlist)

        var id: String {
            switch self {
            case .album(let album):
                "album:\(album.albumArtist)|\(album.title)|\(album.year.map(String.init) ?? "")"
            case .playlist(let playlist):
                "playlist:\(playlist.id.uuidString)"
            }
        }
    }

    /// References, most-recent first. Resolved lazily by `recentPlays`.
    private var recentPlayRefs: [RecentPlay] = []

    /// What the Recents grid shows — resolved against the live library on
    /// every read rather than cached, so a removed album or a deleted
    /// playlist simply stops appearing and a rescan never goes stale.
    var recentPlays: [RecentlyPlayed] {
        recentPlayRefs.compactMap { ref in
            switch ref {
            case .album(let key):
                albumsByKey[key].map(RecentlyPlayed.album)
            case .playlist(let id):
                playlists.first { $0.id == id }.map(RecentlyPlayed.playlist)
            }
        }
    }

    /// Records that a collection was just played: most-recent first,
    /// de-duplicated so replaying yesterday's album moves its tile to the
    /// front rather than adding a second one. Called from
    /// `recordPlayed(_:from:)` — a playlist when the queue was started from
    /// one, otherwise the album the started track belongs to.
    private func recordRecentPlay(_ play: RecentPlay) {
        recentPlayRefs.removeAll { $0 == play }
        recentPlayRefs.insert(play, at: 0)
        if recentPlayRefs.count > Self.recentPlaysLimit {
            recentPlayRefs.removeLast(recentPlayRefs.count - Self.recentPlaysLimit)
        }
        settings.set(Self.encodeRecentPlays(recentPlayRefs), forKey: .recentPlays)
    }

    private static func encodeRecentPlays(_ plays: [RecentPlay]) -> String? {
        guard !plays.isEmpty else { return nil }
        return (try? JSONEncoder().encode(plays)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decodeRecentPlays(_ raw: String?) -> [RecentPlay] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RecentPlay].self, from: data)) ?? []
    }

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
    ///
    /// `playlist` is `PlaybackController.startedFromPlaylist`: non-nil when the
    /// queue was started from a playlist, which is what the Recents grid
    /// credits instead of each track's album as the queue rolls through it.
    func recordPlayed(_ track: Track, from playlist: Playlist.ID? = nil) {
        recentlyPlayedIDs.removeAll { $0 == track.id }
        recentlyPlayedIDs.insert(track.id, at: 0)
        if recentlyPlayedIDs.count > Self.recentlyPlayedLimit {
            recentlyPlayedIDs.removeLast(recentlyPlayedIDs.count - Self.recentlyPlayedLimit)
        }
        settings.set(Self.encode(recentlyPlayedIDs.map(\.uuidString)), forKey: .recentlyPlayed)

        if let playlist {
            recordRecentPlay(.playlist(playlist))
        } else {
            recordRecentPlay(.album(track.albumKey))
        }
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
    /// Playlists match on name alone, in memory — they are few, and the store's
    /// FTS index covers tracks only. Names starting with the query rank first.
    /// Catalogs the same way, by name.
    private func matchingPlaylists(_ needle: String) -> [Playlist] {
        Self.matchingByName(playlists, needle, name: \.name)
    }

    private func matchingCatalogs(_ needle: String) -> [Catalog] {
        Self.matchingByName(catalogs, needle, name: \.name)
    }

    private static func matchingByName<Item>(_ items: [Item], _ needle: String,
                                             name: KeyPath<Item, String>) -> [Item] {
        let fold = { (text: String) in
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let folded = fold(needle)
        var prefixed: [Item] = []
        var rest: [Item] = []
        for item in items {
            let candidate = fold(item[keyPath: name])
            if candidate.hasPrefix(folded) {
                prefixed.append(item)
            } else if candidate.contains(folded) {
                rest.append(item)
            }
        }
        return Array((prefixed + rest).prefix(3))
    }

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
            playlists: matchingPlaylists(needle),
            catalogs: matchingCatalogs(needle),
            tracks: Array(matchedTracks.prefix(3))
        )
    }
}
