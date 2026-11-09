import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// `albums(byArtist:)` is now a cache filled in `load()` rather than a filter
/// and sort on every read — the ordering it used to compute inline still has
/// to hold. See #86.
@Suite("AppModel library derivations")
@MainActor
struct AppModelLibraryTests {

    @Test("An artist's discography comes back oldest first, then by title")
    func discographyIsOrdered() async {
        let tracks = [
            stubTrack("A", artist: "Halvard Ås", album: "Later", year: 2021),
            stubTrack("B", artist: "Halvard Ås", album: "Earliest", year: 2015),
            stubTrack("C", artist: "Halvard Ås", album: "Second B", year: 2018),
            stubTrack("D", artist: "Halvard Ås", album: "Second A", year: 2018),
            stubTrack("E", artist: "Someone Else", album: "Unrelated", year: 2019),
        ]
        let model = AppModel(store: StubLibraryStore(tracks: tracks))
        await model.load()

        #expect(model.albums(byArtist: "Halvard Ås").map(\.title)
                == ["Earliest", "Second A", "Second B", "Later"])
    }

    @Test("An artist with nothing in the library gets an empty list, not a crash")
    func unknownArtistIsEmpty() async {
        let model = AppModel(store: PreviewData.emptyStore())
        await model.load()
        #expect(model.albums(byArtist: "Nobody").isEmpty)
    }

    @Test("The cache survives an album-sort change, which only reorders the grid")
    func discographyIndependentOfAlbumSort() async {
        let tracks = [
            stubTrack("A", artist: "Halvard Ås", album: "Later", year: 2021),
            stubTrack("B", artist: "Halvard Ås", album: "Earliest", year: 2015),
        ]
        let model = AppModel(store: StubLibraryStore(tracks: tracks))
        await model.load()

        model.albumSort = .recentlyAdded
        #expect(model.albums(byArtist: "Halvard Ås").map(\.title) == ["Earliest", "Later"])
    }
}

@Suite("AppModel genres")
@MainActor
struct AppModelGenreTests {

    private func tagged(_ title: String, artist: String, album: String, year: Int,
                        genre: String) -> Track {
        var track = stubTrack(title, artist: artist, album: album, year: year)
        track.genre = genre
        return track
    }

    @Test("Genres load A–Z and each one's albums come back by artist, then year")
    func genresLoadWithOrderedAlbums() async {
        let model = AppModel(store: StubLibraryStore(tracks: [
            tagged("A", artist: "The Zebras", album: "Late", year: 2020, genre: "Rock"),
            tagged("B", artist: "Anvil", album: "Second", year: 2010, genre: "rock"),
            tagged("C", artist: "Anvil", album: "First", year: 2005, genre: "Rock"),
            tagged("D", artist: "Moss", album: "Drift", year: 2015, genre: "Ambient"),
        ]))
        await model.load()

        #expect(model.genres.map(\.name) == ["Ambient", "Rock"])
        #expect(model.albums(inGenre: "rock").map(\.title) == ["First", "Second", "Late"])
        #expect(model.genre(id: "rock")?.albumCount == 3)
        #expect(model.albums(inGenre: "nothing").isEmpty)
    }

    @Test("A genre screen is reachable and Back returns to the library")
    func genreNavigation() {
        let model = AppModel(store: PreviewData.emptyStore())
        model.show(.genre("rock"))
        #expect(model.screen == .genre("rock"))
        model.goBack()
        #expect(model.screen == .library)
    }
}

@Suite("AppModel playlist sort")
@MainActor
struct AppModelPlaylistSortTests {

    private func playlist(_ name: String, daysAgo: Double?) -> Playlist {
        Playlist(name: name, trackIDs: [], duration: 0,
                 updatedAt: daysAgo.map { Date(timeIntervalSinceNow: -$0 * 86_400) })
    }

    private func model(settings: InMemorySettingsStore = InMemorySettingsStore()) async -> AppModel {
        let model = AppModel(
            store: StubLibraryStore(playlists: [
                playlist("Banana", daysAgo: 1),
                playlist("apple", daysAgo: 30),
                playlist("Cherry", daysAgo: nil),
                playlist("Date", daysAgo: 5),
            ]),
            settings: settings)
        await model.load()
        return model
    }

    @Test("A-Z orders by name, ignoring case")
    func alphabetical() async {
        let model = await model()
        #expect(model.sortedPlaylists.map(\.name) == ["apple", "Banana", "Cherry", "Date"])
    }

    @Test("Recently updated puts the newest first and playlists with no date last")
    func recentlyUpdated() async {
        let model = await model()
        model.playlistSort = .recentlyAdded
        #expect(model.sortedPlaylists.map(\.name) == ["Banana", "Date", "apple", "Cherry"])
    }

    @Test("Sorting the grid leaves the sidebar's order alone")
    func sidebarOrderUntouched() async {
        let model = await model()
        let before = model.playlists.map(\.name)
        model.playlistSort = .recentlyAdded
        #expect(model.playlists.map(\.name) == before)
    }

    @Test("The chosen sort is remembered")
    func persists() async {
        let settings = InMemorySettingsStore()
        let first = await model(settings: settings)
        first.playlistSort = .recentlyAdded

        let second = await model(settings: settings)
        #expect(second.playlistSort == .recentlyAdded)
    }
}
