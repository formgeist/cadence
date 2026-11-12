import Testing
import Foundation
@testable import CadenceLibrary
import CadenceCore

/// A store on a fresh temporary database, removed when the test finishes.
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

@Suite("SQLite store — liked songs")
struct LikedTrackStoreTests {

    @Test("A fresh library has nothing liked")
    func startsEmpty() async throws {
        try await withStore { store in
            let liked = try await store.likedTrackIDs()
            #expect(liked.isEmpty)
        }
    }

    @Test("Likes come back newest first, a batch in the order it was given")
    func newestFirst() async throws {
        try await withStore { store in
            let tracks = ["One", "Two", "Three", "Four"].map(makeTrack)
            try await store.upsert(tracks)

            try await store.setLiked(true, trackIDs: [tracks[0].id])
            // Distinct timestamps: a second-resolution clock would tie these.
            try await Task.sleep(for: .milliseconds(20))
            try await store.setLiked(true, trackIDs: [tracks[2].id, tracks[1].id])

            #expect(try await store.likedTrackIDs()
                    == [tracks[2].id, tracks[1].id, tracks[0].id])
        }
    }

    @Test("Liking a track again keeps its place rather than moving it to the top")
    func relikeKeepsOriginalDate() async throws {
        try await withStore { store in
            let tracks = ["One", "Two"].map(makeTrack)
            try await store.upsert(tracks)

            try await store.setLiked(true, trackIDs: [tracks[0].id])
            try await Task.sleep(for: .milliseconds(20))
            try await store.setLiked(true, trackIDs: [tracks[1].id])
            try await Task.sleep(for: .milliseconds(20))
            try await store.setLiked(true, trackIDs: [tracks[0].id])

            #expect(try await store.likedTrackIDs() == [tracks[1].id, tracks[0].id])
        }
    }

    @Test("Unliking removes only the tracks named")
    func unlike() async throws {
        try await withStore { store in
            let tracks = ["One", "Two", "Three"].map(makeTrack)
            try await store.upsert(tracks)
            try await store.setLiked(true, trackIDs: tracks.map(\.id))

            try await store.setLiked(false, trackIDs: [tracks[1].id])

            #expect(Set(try await store.likedTrackIDs()) == [tracks[0].id, tracks[2].id])
        }
    }

    @Test("An id with no track behind it is skipped, not stored and not fatal")
    func unknownIDsSkipped() async throws {
        try await withStore { store in
            let track = makeTrack("One")
            try await store.upsert([track])

            try await store.setLiked(true, trackIDs: [UUID(), track.id])

            #expect(try await store.likedTrackIDs() == [track.id])
        }
    }

    @Test("A track removed from the library leaves Liked Songs with it")
    func removalCascades() async throws {
        try await withStore { store in
            let tracks = ["One", "Two"].map(makeTrack)
            try await store.upsert(tracks)
            try await store.setLiked(true, trackIDs: tracks.map(\.id))

            try await store.remove(trackIDs: [tracks[0].id])
            #expect(try await store.likedTrackIDs() == [tracks[1].id])

            try await store.remove(urls: [tracks[1].url])
            #expect(try await store.likedTrackIDs().isEmpty)
        }
    }

    @Test("A rescan of the same file keeps its like")
    func rescanKeepsLike() async throws {
        try await withStore { store in
            let track = makeTrack("One")
            try await store.upsert([track])
            try await store.setLiked(true, trackIDs: [track.id])

            // The scanner hands back a fresh `Track` with a new id for the
            // same path; the store keeps the row's existing id.
            var rescanned = makeTrack("One")
            rescanned.title = "One (Remastered)"
            try await store.upsert([rescanned])

            #expect(try await store.likedTrackIDs() == [track.id])
        }
    }
}
