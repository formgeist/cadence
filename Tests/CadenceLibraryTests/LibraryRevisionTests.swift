import Testing
import Foundation
@testable import CadenceLibrary
import CadenceCore

private func withStore<T>(_ body: (SQLiteLibraryStore) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cadence-db-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
    return try await body(store)
}

private func makeTrack(_ title: String) -> Track {
    Track(url: URL(fileURLWithPath: "/music/Slow Hours/\(title).flac"),
          title: title, artist: "Vera Lindqvist", albumTitle: "Sound of the Slow Hours",
          year: 2023, duration: 200)
}

@Suite("SQLite store — library revision")
struct LibraryRevisionTests {

    /// Runs `change` and reports whether the revision moved.
    private func moves(_ store: SQLiteLibraryStore,
                       _ change: () async throws -> Void) async throws -> Bool {
        let before = try await store.libraryRevision()
        try await change()
        return try await store.libraryRevision() != before
    }

    @Test("Songs added, retagged and removed each move the revision")
    func songs() async throws {
        try await withStore { store in
            var track = makeTrack("Morning Static")
            let moved1 = try await moves(store) { try await store.upsert([track]) }
            #expect(moved1)
            track.title = "Morning Static (Remastered)"
            let moved2 = try await moves(store) { try await store.upsert([track]) }
            #expect(moved2)
            let moved3 = try await moves(store) { try await store.remove(trackIDs: [track.id]) }
            #expect(moved3)
        }
    }

    @Test("Playlist edits move the revision")
    func playlists() async throws {
        try await withStore { store in
            let track = makeTrack("Morning Static")
            try await store.upsert([track])
            var playlist: Playlist?
            let moved4 = try await moves(store) { playlist = try await store.createPlaylist(named: "Mornings") }
            #expect(moved4)
            let id = try #require(playlist?.id)
            let moved5 = try await moves(store) { try await store.addTracks([track.id], to: id) }
            #expect(moved5)
            let moved6 = try await moves(store) { try await store.renamePlaylist(id, to: "Early") }
            #expect(moved6)
            let moved7 = try await moves(store) { try await store.removeTracks(atOffsets: [0], from: id) }
            #expect(moved7)
            let moved8 = try await moves(store) { try await store.deletePlaylist(id) }
            #expect(moved8)
        }
    }

    @Test("Liking and unliking move the revision")
    func likes() async throws {
        try await withStore { store in
            let track = makeTrack("Morning Static")
            try await store.upsert([track])
            let moved9 = try await moves(store) { try await store.setLiked(true, trackIDs: [track.id]) }
            #expect(moved9)
            let moved10 = try await moves(store) { try await store.setLiked(false, trackIDs: [track.id]) }
            #expect(moved10)
        }
    }

    @Test("Playing a song does not move the revision")
    func plays() async throws {
        try await withStore { store in
            let track = makeTrack("Morning Static")
            try await store.upsert([track])
            let moved = try await moves(store) {
                try await store.record(PlayRecord(track: track, playedAt: Date()))
            }
            #expect(!moved)
        }
    }

    @Test("A write through another connection to the same file is seen")
    func otherConnection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let app = try SQLiteLibraryStore(url: url)
        let server = try SQLiteLibraryStore(url: url)
        let before = try await server.libraryRevision()
        try await app.upsert([makeTrack("Morning Static")])
        #expect(try await server.libraryRevision() != before)
    }
}
