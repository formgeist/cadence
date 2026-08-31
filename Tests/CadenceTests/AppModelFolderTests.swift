import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// Removing a music folder drops its bookmark (via `forgetFolder`) and takes
/// every track the library held from inside it — see #33. The store side is
/// stubbed; what matters here is that the model matches the right tracks, only
/// forgets the folder once the write lands, and reports what happened.
@Suite("AppModel folder removal")
@MainActor
struct AppModelFolderTests {

    private func track(_ path: String, title: String) -> Track {
        Track(url: URL(fileURLWithPath: path), title: title, artist: "Vera Lindqvist",
              albumTitle: "Slow Hours", year: 2023, duration: 100)
    }

    @Test("Only descendants count — a sibling folder with a lookalike name is left alone")
    func matchesByPathComponent() async {
        let tracks = [
            track("/Users/x/Music/a.flac", title: "A"),
            track("/Users/x/Music/Live/b.flac", title: "B"),
            track("/Users/x/Music Backup/c.flac", title: "C"),
        ]
        let model = AppModel(store: StubLibraryStore(tracks: tracks))
        await model.load()

        let under = model.tracks(under: URL(fileURLWithPath: "/Users/x/Music"))
        #expect(Set(under.map(\.title)) == ["A", "B"])
    }

    @Test("Removing a folder takes its tracks and forgets the bookmark")
    func removesTracksAndForgets() async {
        let tracks = [
            track("/Users/x/Music/a.flac", title: "A"),
            track("/Users/x/Music/b.flac", title: "B"),
            track("/Users/x/Other/c.flac", title: "C"),
        ]
        let store = StubLibraryStore(tracks: tracks)
        let model = AppModel(store: store)
        await model.load()

        var forgotten: [URL] = []
        model.forgetFolder = { forgotten.append($0) }

        let folder = URL(fileURLWithPath: "/Users/x/Music")
        let doomed = Set(model.tracks(under: folder).map(\.id))
        await model.removeFolder(folder)

        #expect(forgotten == [folder])
        #expect(Set(await store.removedTrackIDs) == doomed)
        #expect(model.notice?.contains("2 tracks") == true)
        #expect(model.actionError == nil)
    }

    @Test("A folder that had nothing in the library is still forgotten")
    func forgetsEmptyFolder() async {
        let model = AppModel(store: StubLibraryStore(tracks: [
            track("/Users/x/Music/a.flac", title: "A"),
        ]))
        await model.load()

        var forgotten: [URL] = []
        model.forgetFolder = { forgotten.append($0) }

        await model.removeFolder(URL(fileURLWithPath: "/Users/x/Empty"))

        #expect(forgotten == [URL(fileURLWithPath: "/Users/x/Empty")])
        #expect(model.allTracks.map(\.title) == ["A"])
        #expect(model.actionError == nil)
    }

    @Test("A failed store write leaves the folder on the list to try again")
    func keepsFolderWhenRemovalFails() async {
        let store = StubLibraryStore(tracks: [
            track("/Users/x/Music/a.flac", title: "A"),
        ], failing: [.remove])
        let model = AppModel(store: store)
        await model.load()

        var forgotten: [URL] = []
        model.forgetFolder = { forgotten.append($0) }

        await model.removeFolder(URL(fileURLWithPath: "/Users/x/Music"))

        #expect(forgotten.isEmpty)
        #expect(model.allTracks.map(\.title) == ["A"])
        #expect(model.actionError?.contains("disk is full") == true)
    }
}
