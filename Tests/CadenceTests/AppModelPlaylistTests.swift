import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// The playlist logic that lives above the store: the `edit(_:failing:)`
/// funnel, `entries(in:)`'s occurrence mapping, `deletePlaylist`'s navigation
/// side effect, and `suggestedPlaylistName`. See #44 — the store-level suites
/// pass right through these.
@Suite("AppModel playlists")
@MainActor
struct AppModelPlaylistTests {

    // MARK: suggestedPlaylistName

    @Test("The first suggestion is the bare name")
    func suggestsBareNameWhenFree() async {
        let model = AppModel(store: PreviewData.emptyStore())
        await model.load()
        #expect(model.suggestedPlaylistName == "New Playlist")
    }

    @Test("A taken name bumps to the next free number, skipping the ones in use")
    func suggestsNextFreeNumber() async {
        let store = StubLibraryStore(playlists: [
            Playlist(name: "New Playlist", trackIDs: [], duration: 0),
            Playlist(name: "New Playlist 2", trackIDs: [], duration: 0),
        ])
        let model = AppModel(store: store)
        await model.load()
        #expect(model.suggestedPlaylistName == "New Playlist 3")
    }

    // MARK: entries(in:)

    @Test("A playlist holding one track twice maps to two rows with distinct ids")
    func entriesNumberDuplicateOccurrences() async throws {
        let a = stubTrack("Morning Static")
        let b = stubTrack("Slow Hours")
        let playlist = Playlist(name: "Late Desk",
                                trackIDs: [a.id, b.id, a.id], duration: 300)
        let model = AppModel(store: StubLibraryStore(tracks: [a, b], playlists: [playlist]))
        await model.load()

        let entries = model.entries(in: try #require(model.playlist(id: playlist.id)))
        #expect(entries.map(\.position) == [0, 1, 2])
        #expect(entries.map(\.track.id) == [a.id, b.id, a.id])
        // The two copies of `a` differ only by occurrence — this is what stops
        // a drag from diffing against itself. See #25.
        #expect(entries.map(\.id.occurrence) == [0, 0, 1])
        #expect(Set(entries.map(\.id)).count == 3)
    }

    @Test("An id with no track behind it is dropped, and positions keep the gap")
    func entriesSkipMissingTracks() async throws {
        let a = stubTrack("Morning Static")
        let playlist = Playlist(name: "Late Desk",
                                trackIDs: [a.id, UUID(), a.id], duration: 200)
        let model = AppModel(store: StubLibraryStore(tracks: [a], playlists: [playlist]))
        await model.load()

        let entries = model.entries(in: try #require(model.playlist(id: playlist.id)))
        #expect(entries.map(\.position) == [0, 2])
        #expect(entries.map(\.id.occurrence) == [0, 1])
    }

    // MARK: deletePlaylist navigation

    @Test("Deleting the playlist you are looking at returns to the Playlists shelf")
    func deleteLeavesTheDeadScreen() async throws {
        let playlist = Playlist(name: "Late Desk", trackIDs: [], duration: 0)
        let model = AppModel(store: StubLibraryStore(playlists: [playlist]))
        await model.load()
        model.show(.playlist(playlist.id))

        await model.deletePlaylist(playlist)

        #expect(model.screen == .library)
        #expect(model.tab == .playlists)
        #expect(model.playlist(id: playlist.id) == nil)
    }

    @Test("Deleting a playlist you are not looking at leaves the screen alone")
    func deleteElsewhereKeepsScreen() async throws {
        let shown = Playlist(name: "Shown", trackIDs: [], duration: 0)
        let other = Playlist(name: "Other", trackIDs: [], duration: 0)
        let model = AppModel(store: StubLibraryStore(playlists: [shown, other]))
        await model.load()
        model.show(.playlist(shown.id))

        await model.deletePlaylist(other)

        #expect(model.screen == .playlist(shown.id))
    }

    // MARK: moveInPlaylist / removeFromPlaylist

    @Test("Reordering rewrites the playlist with SwiftUI's onMove semantics")
    func moveReordersThePlaylist() async throws {
        let tracks = (1...4).map { stubTrack("Track \($0)") }
        let playlist = Playlist(name: "Late Desk",
                                trackIDs: tracks.map(\.id), duration: 400)
        let model = AppModel(store: StubLibraryStore(tracks: tracks, playlists: [playlist]))
        await model.load()

        await model.moveInPlaylist(playlist, fromOffsets: IndexSet([0]), toOffset: 3)

        let reordered = try #require(model.playlist(id: playlist.id))
        #expect(reordered.trackIDs
                == [tracks[1].id, tracks[2].id, tracks[0].id, tracks[3].id])
        #expect(model.actionError == nil)
    }

    @Test("Removing by offset takes one of two identical entries and reloads")
    func removeTakesOneOffset() async throws {
        let track = stubTrack("Slow Hours")
        let playlist = Playlist(name: "Late Desk",
                                trackIDs: [track.id, track.id], duration: 200)
        let model = AppModel(store: StubLibraryStore(tracks: [track], playlists: [playlist]))
        await model.load()

        await model.removeFromPlaylist(playlist, atOffsets: IndexSet([0]))

        let trimmed = try #require(model.playlist(id: playlist.id))
        #expect(trimmed.trackIDs == [track.id])
        #expect(model.entries(in: trimmed).count == 1)
        #expect(model.actionError == nil)
    }

    // MARK: edit(_:failing:)

    @Test("A failed rename names the playlist and the verb in actionError")
    func failedRenameReportsByName() async {
        let playlist = Playlist(name: "Late Desk", trackIDs: [], duration: 0)
        let model = AppModel(store: StubLibraryStore(
            playlists: [playlist], failing: [.renamePlaylist]))
        await model.load()

        await model.renamePlaylist(playlist, to: "Headphones Only")

        let error = model.actionError
        #expect(error?.contains("Late Desk") == true)
        #expect(error?.contains("rename") == true)
        #expect(error?.contains("disk is full") == true)
    }

    @Test("A failed add posts no success notice")
    func failedAddSuppressesNotice() async {
        let track = stubTrack("Slow Hours")
        let playlist = Playlist(name: "Late Desk", trackIDs: [], duration: 0)
        let model = AppModel(store: StubLibraryStore(
            tracks: [track], playlists: [playlist], failing: [.addTracks]))
        await model.load()

        await model.addTracks([track.id], to: playlist.id)

        #expect(model.notice == nil)
        #expect(model.actionError?.contains("add to") == true)
    }

    @Test("A successful add posts a notice counting the tracks the library still knows")
    func successfulAddPostsNotice() async {
        let track = stubTrack("Slow Hours")
        let playlist = Playlist(name: "Late Desk", trackIDs: [], duration: 0)
        let model = AppModel(store: StubLibraryStore(tracks: [track], playlists: [playlist]))
        await model.load()

        await model.addTracks([track.id, UUID()], to: playlist.id)

        #expect(model.notice == "Added 1 track to “Late Desk”")
        #expect(model.actionError == nil)
    }

    // MARK: createPlaylist

    @Test("A failed create reports the chosen name and does not navigate")
    func failedCreateReportsAndStaysPut() async {
        let model = AppModel(store: StubLibraryStore(failing: [.createPlaylist]))
        await model.load()

        await model.createPlaylist(named: "Sunday Vinyl Rips")

        #expect(model.actionError?.contains("Sunday Vinyl Rips") == true)
        #expect(model.screen == .library)
    }

    @Test("An empty name falls back to the suggestion rather than creating “”")
    func emptyNameFallsBackToSuggestion() async {
        let model = AppModel(store: StubLibraryStore())
        await model.load()

        await model.createPlaylist(named: "   ")

        #expect(model.playlists.map(\.name) == ["New Playlist"])
        #expect(model.screen == .playlist(model.playlists[0].id))
    }
}
