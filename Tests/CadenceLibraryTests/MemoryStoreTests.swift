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

private let album = Album.Key(albumArtist: "Vera Lindqvist",
                              title: "Sound of the Slow Hours", year: 2023)

@Suite("SQLite store — memories")
struct MemoryStoreTests {

    @Test("A note on a record and a note on a song both round-trip")
    func roundTrip() async throws {
        try await withStore { store in
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let onAlbum = Memory(subject: .album(album), text: "First winter in the flat.",
                                 createdAt: created)
            let onSong = Memory(subject: .track(title: "Anhedonia", artist: "Vera Lindqvist",
                                                album: album),
                                text: "Ingrid's call.", createdAt: created + 60)
            try await store.saveMemory(onAlbum)
            try await store.saveMemory(onSong)

            let fetched = try await store.memories()
            #expect(fetched.count == 2)
            #expect(fetched.first { $0.id == onAlbum.id } == onAlbum)
            #expect(fetched.first { $0.id == onSong.id } == onSong)
        }
    }

    @Test("An untagged year stays nil, not zero")
    func nilYear() async throws {
        try await withStore { store in
            let key = Album.Key(albumArtist: "Halvard Ås", title: "Nocturne", year: nil)
            let memory = Memory(subject: .album(key), text: "Late shift.")
            try await store.saveMemory(memory)
            #expect(try await store.memories().first?.subject == .album(key))
        }
    }

    @Test("Saving the same id again changes the text and keeps the creation date")
    func update() async throws {
        try await withStore { store in
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            var memory = Memory(subject: .album(album), text: "First draft.", createdAt: created)
            try await store.saveMemory(memory)

            memory.text = "Second draft."
            memory.updatedAt = created + 3_600
            try await store.saveMemory(memory)

            let fetched = try await store.memories()
            #expect(fetched.count == 1)
            #expect(fetched.first?.text == "Second draft.")
            #expect(fetched.first?.createdAt == created)
            #expect(fetched.first?.updatedAt == created + 3_600)
        }
    }

    @Test("Deleting removes only that note")
    func delete() async throws {
        try await withStore { store in
            let keep = Memory(subject: .album(album), text: "Keep.")
            let drop = Memory(subject: .album(album), text: "Drop.")
            try await store.saveMemory(keep)
            try await store.saveMemory(drop)

            try await store.deleteMemory(drop.id)

            #expect(try await store.memories().map(\.id) == [keep.id])
        }
    }

    @Test("A note outlives its record leaving the library")
    func outlivesTracks() async throws {
        try await withStore { store in
            let track = Track(url: URL(fileURLWithPath: "/music/a.flac"), title: "Anhedonia",
                              artist: "Vera Lindqvist", albumTitle: album.title,
                              year: album.year, duration: 200)
            try await store.upsert([track])
            try await store.saveMemory(Memory(subject: .init(track: track), text: "Still here."))

            try await store.remove(trackIDs: [track.id])

            #expect(try await store.memories().map(\.text) == ["Still here."])
        }
    }
}
