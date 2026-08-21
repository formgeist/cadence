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

private func makeTrack(
    _ title: String,
    artist: String = "Vera Lindqvist",
    albumArtist: String? = nil,
    album: String = "Sound of the Slow Hours",
    year: Int? = 2023,
    composer: String? = nil,
    number: Int? = 1,
    disc: Int? = nil,
    seconds: TimeInterval = 200,
    path: String? = nil
) -> Track {
    Track(
        url: URL(fileURLWithPath: path ?? "/music/\(album)/\(title).flac"),
        title: title,
        artist: artist,
        albumArtist: albumArtist ?? artist,
        albumTitle: album,
        composer: composer,
        year: year,
        trackNumber: number,
        discNumber: disc,
        duration: seconds,
        format: .hiRes)
}

@Suite("SQLite store")
struct SQLiteLibraryStoreTests {

    @Test("Tracks survive a round trip with their metadata intact")
    func roundTrip() async throws {
        try await withStore { store in
            let track = makeTrack("Slow Hours", composer: "Benjamin Britten", number: 2)
            try await store.upsert([track])

            let fetched = try #require(try await store.allTracks().first)
            #expect(fetched.title == "Slow Hours")
            #expect(fetched.composer == "Benjamin Britten")
            #expect(fetched.trackNumber == 2)
            #expect(fetched.format.bitDepth == 24)
            #expect(fetched.id == track.id)
        }
    }

    @Test("Re-importing the same path updates the row and keeps its id")
    func upsertByPath() async throws {
        try await withStore { store in
            let original = makeTrack("Slow Hours")
            try await store.upsert([original])

            // A retag produces a new Track value for the same file.
            var retagged = makeTrack("Slow Hours (Remastered)")
            retagged.url = original.url
            try await store.upsert([retagged])

            let all = try await store.allTracks()
            #expect(all.count == 1)
            #expect(all[0].title == "Slow Hours (Remastered)")
            // The id must survive, or every playlist pointing at this file
            // breaks on the next rescan.
            #expect(all[0].id == original.id)
        }
    }

    @Test("Albums group by artist, title and year")
    func albumGrouping() async throws {
        try await withStore { store in
            try await store.upsert([
                makeTrack("A", number: 1),
                makeTrack("B", number: 2),
                makeTrack("C", year: 2025, number: 1, path: "/music/remaster/C.flac"),
            ])

            let albums = try await store.albums()
            #expect(albums.count == 2)
            #expect(Set(albums.map(\.year)) == [2023, 2025])
        }
    }

    @Test("An album with no year is found by its own key, not treated as a wildcard")
    func nilYearKey() async throws {
        try await withStore { store in
            try await store.upsert([makeTrack("Untitled", year: nil)])
            let key = Album.Key(albumArtist: "Vera Lindqvist",
                                title: "Sound of the Slow Hours", year: nil)
            let album = try await store.album(for: key)
            #expect(album?.trackCount == 1)
        }
    }

    @Test("Artists aggregate album and track counts")
    func artistAggregation() async throws {
        try await withStore { store in
            try await store.upsert([
                makeTrack("A", number: 1),
                makeTrack("B", number: 2),
                makeTrack("C", album: "Northerly", year: 2022,
                          path: "/music/Northerly/C.flac"),
            ])

            let artist = try #require(try await store.artists().first)
            #expect(artist.name == "Vera Lindqvist")
            #expect(artist.albumCount == 2)
            #expect(artist.trackCount == 3)
            #expect(artist.formats == ["FLAC"])
        }
    }

    @Test("Removing a file drops it from the library")
    func removal() async throws {
        try await withStore { store in
            let track = makeTrack("Slow Hours")
            try await store.upsert([track])
            try await store.remove(urls: [track.url])
            #expect(try await store.allTracks().isEmpty)
        }
    }

    @Test("Library size sums the file sizes the scanner reported")
    func librarySize() async throws {
        try await withStore { store in
            try await store.upsert([
                (makeTrack("A"), Int64(1_000)),
                (makeTrack("B", path: "/music/b.flac"), Int64(2_500)),
            ])
            #expect(try await store.librarySize() == 3_500)
        }
    }

    @Test("Playlists round-trip, and entries for missing tracks are dropped")
    func playlists() async throws {
        try await withStore { store in
            let track = makeTrack("Slow Hours")
            try await store.upsert([track])

            let ghost = UUID()
            try await store.replacePlaylists([
                Playlist(name: "Late Desk", trackIDs: [track.id, ghost], duration: 0),
            ])

            let fetched = try #require(try await store.playlists().first)
            #expect(fetched.name == "Late Desk")
            // The ghost id references no row; keeping it would mean a playlist
            // that plays silence.
            #expect(fetched.trackIDs == [track.id])
            #expect(fetched.duration == 200)
        }
    }

    @Test("A created playlist is empty, named, and comes back in order")
    func createPlaylist() async throws {
        try await withStore { store in
            let first = try await store.createPlaylist(named: "Late Desk")
            let second = try await store.createPlaylist(named: "Headphones Only")

            #expect(first.trackIDs.isEmpty)
            #expect(first.duration == 0)

            let fetched = try await store.playlists()
            #expect(fetched.map(\.name) == ["Late Desk", "Headphones Only"])
            #expect(fetched.map(\.id) == [first.id, second.id])
        }
    }

    @Test("Two playlists may share a name and stay separate rows")
    func duplicateNames() async throws {
        try await withStore { store in
            let first = try await store.createPlaylist(named: "Untitled")
            let second = try await store.createPlaylist(named: "Untitled")

            #expect(first.id != second.id)
            #expect(try await store.playlists().count == 2)
        }
    }

    @Test("Tracks append in the order given, and the total follows")
    func addTracks() async throws {
        try await withStore { store in
            let tracks = (1...3).map { makeTrack("Track \($0)", number: $0, seconds: 100) }
            try await store.upsert(tracks)
            let playlist = try await store.createPlaylist(named: "Late Desk")

            try await store.addTracks([tracks[2].id, tracks[0].id], to: playlist.id)
            try await store.addTracks([tracks[1].id], to: playlist.id)

            let fetched = try #require(try await store.playlists().first)
            #expect(fetched.trackIDs == [tracks[2].id, tracks[0].id, tracks[1].id])
            #expect(fetched.duration == 300)
        }
    }

    @Test("Editing one playlist leaves the others alone")
    func editsAreLocal() async throws {
        try await withStore { store in
            let track = makeTrack("Slow Hours")
            try await store.upsert([track])
            let edited = try await store.createPlaylist(named: "Late Desk")
            let untouched = try await store.createPlaylist(named: "Headphones Only")
            try await store.addTracks([track.id], to: untouched.id)

            try await store.addTracks([track.id], to: edited.id)
            try await store.renamePlaylist(edited.id, to: "Late Desk, Revised")

            let fetched = try await store.playlists()
            #expect(fetched.map(\.name) == ["Late Desk, Revised", "Headphones Only"])
            // The whole point of the per-playlist methods: the other playlist
            // keeps its id, its position and its contents.
            #expect(fetched.last?.id == untouched.id)
            #expect(fetched.last?.trackIDs == [track.id])
        }
    }

    @Test("The same track may sit in a playlist twice, and one copy can leave")
    func duplicateEntries() async throws {
        try await withStore { store in
            let track = makeTrack("Slow Hours")
            try await store.upsert([track])
            let playlist = try await store.createPlaylist(named: "Late Desk")

            try await store.addTracks([track.id, track.id], to: playlist.id)
            #expect(try await store.playlists().first?.trackIDs.count == 2)

            // By offset, not by id: removing "the track" would empty the
            // playlist rather than remove the row that was clicked.
            try await store.removeTracks(atOffsets: IndexSet([0]), from: playlist.id)
            #expect(try await store.playlists().first?.trackIDs == [track.id])
        }
    }

    @Test("Removing renumbers, so the next append lands at the end")
    func removeThenAppend() async throws {
        try await withStore { store in
            let tracks = (1...3).map { makeTrack("Track \($0)", number: $0) }
            try await store.upsert(tracks)
            let playlist = try await store.createPlaylist(named: "Late Desk")
            try await store.addTracks(tracks.map(\.id), to: playlist.id)

            try await store.removeTracks(atOffsets: IndexSet([0, 1]), from: playlist.id)
            try await store.addTracks([tracks[0].id], to: playlist.id)

            #expect(try await store.playlists().first?.trackIDs
                    == [tracks[2].id, tracks[0].id])
        }
    }

    @Test("Reordering rewrites the order and nothing else")
    func moveTracks() async throws {
        try await withStore { store in
            let tracks = (1...4).map { makeTrack("Track \($0)", number: $0) }
            try await store.upsert(tracks)
            let playlist = try await store.createPlaylist(named: "Late Desk")
            try await store.addTracks(tracks.map(\.id), to: playlist.id)

            // SwiftUI's semantics: the destination indexes the original array.
            try await store.moveTracks(fromOffsets: IndexSet([0]), toOffset: 3,
                                       in: playlist.id)

            #expect(try await store.playlists().first?.trackIDs
                    == [tracks[1].id, tracks[2].id, tracks[0].id, tracks[3].id])
        }
    }

    @Test("Adding a track that has left the library adds nothing, and no gap")
    func addGhostTrack() async throws {
        try await withStore { store in
            let track = makeTrack("Slow Hours")
            try await store.upsert([track])
            let playlist = try await store.createPlaylist(named: "Late Desk")

            try await store.addTracks([UUID(), track.id], to: playlist.id)
            try await store.addTracks([track.id], to: playlist.id)

            // The ghost spent no position, so the second append did not land
            // on top of the first.
            #expect(try await store.playlists().first?.trackIDs == [track.id, track.id])
        }
    }

    @Test("Deleting a playlist takes its items with it")
    func deletePlaylist() async throws {
        try await withStore { store in
            let track = makeTrack("Slow Hours")
            try await store.upsert([track])
            let playlist = try await store.createPlaylist(named: "Late Desk")
            try await store.addTracks([track.id], to: playlist.id)

            try await store.deletePlaylist(playlist.id)

            #expect(try await store.playlists().isEmpty)
            // The track itself is library, not playlist, and stays.
            #expect(try await store.allTracks().count == 1)
        }
    }

    @Test("Removing a track from the library removes it from playlists")
    func removingTrackCascades() async throws {
        try await withStore { store in
            let track = makeTrack("Slow Hours")
            let kept = makeTrack("Undertow", number: 2)
            try await store.upsert([track, kept])
            let playlist = try await store.createPlaylist(named: "Late Desk")
            try await store.addTracks([track.id, kept.id], to: playlist.id)

            try await store.remove(urls: [track.url])

            #expect(try await store.playlists().first?.trackIDs == [kept.id])
        }
    }
}

/// Search is the part PLAN.md §1 calls out as unfinished: `upsert` wrote the
/// track row but not the denormalised search columns, so search returned
/// nothing. These tests exist to keep that from regressing.
@Suite("FTS5 search")
struct SearchTests {

    @Test("Upsert populates the search index, so search finds what was imported")
    func searchAfterUpsert() async throws {
        try await withStore { store in
            try await store.upsert([makeTrack("Slow Hours")])
            let results = try await store.tracks(matching: "slow")
            #expect(results.count == 1)
            #expect(results[0].title == "Slow Hours")
        }
    }

    @Test("Partial words match, so results appear while you are still typing")
    func prefixMatching() async throws {
        try await withStore { store in
            try await store.upsert([makeTrack("Slow Hours")])
            #expect(try await store.tracks(matching: "slow ho").count == 1)
            #expect(try await store.tracks(matching: "s").count == 1)
        }
    }

    @Test("Album, artist and composer are all searchable")
    func searchableColumns() async throws {
        try await withStore { store in
            try await store.upsert([
                makeTrack("Passacaglia", artist: "Cyrille Marchand",
                          album: "Aldeburgh", composer: "Benjamin Britten"),
            ])
            #expect(try await store.tracks(matching: "cyrille").count == 1)
            #expect(try await store.tracks(matching: "aldeburgh").count == 1)
            #expect(try await store.tracks(matching: "britten").count == 1)
        }
    }

    @Test("Diacritics are folded, so ASCII typing finds accented names")
    func diacritics() async throws {
        try await withStore { store in
            try await store.upsert([makeTrack("Nocturne", artist: "Halvard Ås")])
            #expect(try await store.tracks(matching: "halvard as").count == 1)
        }
    }

    @Test("Re-importing does not leave a stale index entry behind")
    func indexFollowsUpdates() async throws {
        try await withStore { store in
            // An album title that shares no words with either track title,
            // so the assertion is about the title alone.
            let original = makeTrack("Anhedonia", album: "Northerly")
            try await store.upsert([original])

            var retagged = makeTrack("Morning Static", album: "Northerly")
            retagged.url = original.url
            try await store.upsert([retagged])

            #expect(try await store.tracks(matching: "morning").count == 1)
            // The old title must not still be findable — one file, one entry.
            #expect(try await store.tracks(matching: "anhedonia").isEmpty)
        }
    }

    @Test("Removing a track removes it from search too")
    func removalClearsIndex() async throws {
        try await withStore { store in
            let track = makeTrack("Slow Hours")
            try await store.upsert([track])
            try await store.remove(urls: [track.url])
            #expect(try await store.tracks(matching: "slow").isEmpty)
        }
    }

    @Test("Punctuation a user types cannot become FTS5 syntax")
    func hostileQueries() async throws {
        try await withStore { store in
            try await store.upsert([makeTrack("Slow Hours")])
            // Each of these is valid FTS5 operator syntax if passed through raw.
            for query in ["\"", "OR", "slow AND", "*", "NEAR(", "()", "^", "-"] {
                _ = try await store.tracks(matching: query)
            }
        }
    }

    @Test("An empty query returns nothing rather than everything")
    func emptyQuery() async throws {
        try await withStore { store in
            try await store.upsert([makeTrack("Slow Hours")])
            #expect(try await store.tracks(matching: "   ").isEmpty)
        }
    }
}
