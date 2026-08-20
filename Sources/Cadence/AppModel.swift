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
    private(set) var isLoading = true
    private(set) var loadError: String?

    let store: any LibraryStore

    init(store: any LibraryStore) {
        self.store = store
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            allTracks = try await store.allTracks()
            albums = try await store.albums()
            artists = try await store.artists()
            playlists = try await store.playlists()
            librarySize = try await store.librarySize()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func album(for key: Album.Key) -> Album? {
        albums.first { $0.key == key }
    }

    var currentAlbum: Album? {
        guard case .album(let key) = screen else { return nil }
        return album(for: key)
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

    /// Artists bucketed by initial, the way the design sections them.
    var artistSections: [ArtistSection] {
        let grouped = Dictionary(grouping: artists, by: \.sortLetter)
        return grouped.keys.sorted().map { letter in
            ArtistSection(letter: letter, artists: grouped[letter] ?? [])
        }
    }

    struct ArtistSection: Identifiable {
        var letter: String
        var artists: [Artist]
        var id: String { letter }
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
