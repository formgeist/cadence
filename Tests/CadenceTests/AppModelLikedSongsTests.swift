import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// Liked Songs as the model keeps it: loaded with the library, flipped by the
/// heart at once, written through, and put back when the write fails.
@Suite("AppModel liked songs")
@MainActor
struct AppModelLikedSongsTests {

    @Test("Likes load with the library, newest first, and resolve to tracks")
    func loadsLikes() async {
        let a = stubTrack("Morning Static")
        let b = stubTrack("Slow Hours")
        let c = stubTrack("Anhedonia")
        let model = AppModel(store: StubLibraryStore(tracks: [a, b, c], liked: [c.id, a.id]))
        await model.load()

        #expect(model.likedTracks.map(\.id) == [c.id, a.id])
        #expect(model.isLiked(a))
        #expect(!model.isLiked(b))
        #expect(model.likedSongsSummary == "2 tracks")
    }

    @Test("Liking puts the track at the top and survives a reload")
    func likeIsWrittenThrough() async {
        let a = stubTrack("Morning Static")
        let b = stubTrack("Slow Hours")
        let store = StubLibraryStore(tracks: [a, b], liked: [a.id])
        let model = AppModel(store: store)
        await model.load()

        await model.toggleLike(b)
        #expect(model.likedTracks.map(\.id) == [b.id, a.id])

        let reloaded = AppModel(store: store)
        await reloaded.load()
        #expect(reloaded.likedTracks.map(\.id) == [b.id, a.id])
    }

    @Test("Unliking takes the track out of Liked Songs")
    func unlike() async throws {
        let a = stubTrack("Morning Static")
        let b = stubTrack("Slow Hours")
        let store = StubLibraryStore(tracks: [a, b], liked: [b.id, a.id])
        let model = AppModel(store: store)
        await model.load()

        await model.toggleLike(b)

        #expect(model.likedTracks.map(\.id) == [a.id])
        #expect(!model.isLiked(b))
        #expect(try await store.likedTrackIDs() == [a.id])
    }

    @Test("A failed write puts the heart back and says what went wrong")
    func failureReverts() async {
        let a = stubTrack("Morning Static")
        let model = AppModel(store: StubLibraryStore(tracks: [a], failing: [.setLiked]))
        await model.load()

        await model.toggleLike(a)

        #expect(!model.isLiked(a))
        #expect(model.likedTracks.isEmpty)
        #expect(model.actionError == "Could not like “Morning Static”: disk is full")
    }

    @Test("A like from a menu is announced; one from the heart is not")
    func announce() async {
        let a = stubTrack("Morning Static")
        let b = stubTrack("Slow Hours")
        let model = AppModel(store: StubLibraryStore(tracks: [a, b]))
        await model.load()

        await model.toggleLike(a)
        #expect(model.notice == nil)

        await model.toggleLike(b, announce: true)
        #expect(model.notice == "Added “Slow Hours” to Liked Songs")

        await model.toggleLike(b, announce: true)
        #expect(model.notice == "Removed “Slow Hours” from Liked Songs")
    }

    @Test("Liking what is already liked changes nothing and writes nothing")
    func idempotent() async {
        let a = stubTrack("Morning Static")
        let b = stubTrack("Slow Hours")
        // The store would fail any write, so a no-op is the only way through
        // without an error.
        let model = AppModel(store: StubLibraryStore(tracks: [a, b], liked: [a.id, b.id],
                                                     failing: [.setLiked]))
        await model.load()

        await model.setLiked(true, [b])

        #expect(model.likedTracks.map(\.id) == [a.id, b.id])
        #expect(model.actionError == nil)
    }

    @Test("A liked id with no track behind it is not listed")
    func missingTracksDropOut() async {
        let a = stubTrack("Morning Static")
        let model = AppModel(store: StubLibraryStore(tracks: [a], liked: [UUID(), a.id]))
        await model.load()

        #expect(model.likedTracks.map(\.id) == [a.id])
        #expect(model.likedSongsSummary == "1 track")
    }

    @Test("Liked Songs is a screen of its own that Back returns from")
    func navigation() async {
        let model = AppModel(store: StubLibraryStore(tracks: [stubTrack("Morning Static")]))
        await model.load()

        model.show(.likedSongs)
        #expect(model.screen == .likedSongs)
        model.goBack()
        #expect(model.screen == .library)
    }
}
