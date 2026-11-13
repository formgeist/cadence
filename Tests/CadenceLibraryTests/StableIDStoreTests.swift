import Testing
import Foundation
import GRDB
@testable import CadenceLibrary
import CadenceCore

private func temporaryDatabaseURL() -> (directory: URL, database: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cadence-ids-\(UUID().uuidString)")
    return (directory, directory.appendingPathComponent("library.sqlite"))
}

private func makeTrack(
    _ title: String, albumArtist: String = "Vera Lindqvist",
    album: String = "Sound of the Slow Hours", year: Int? = 2023
) -> Track {
    Track(
        url: URL(fileURLWithPath: "/music/\(albumArtist)/\(album)/\(title).flac"),
        title: title, artist: albumArtist, albumArtist: albumArtist,
        albumTitle: album, year: year, duration: 200)
}

@Suite("Stable album and artist ids in the store")
struct StableIDStoreTests {

    @Test("An upserted album and its artist resolve from their ids")
    func resolves() async throws {
        let (directory, url) = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteLibraryStore(url: url)
        try await store.upsert([makeTrack("Slow Hours"), makeTrack("Low Tide")])

        let key = Album.Key(albumArtist: "Vera Lindqvist",
                            title: "Sound of the Slow Hours", year: 2023)
        #expect(try await store.albumKey(forStableID: key.stableID) == key)
        #expect(try await store.artistName(
            forStableID: StableID.artist(named: "Vera Lindqvist")) == "Vera Lindqvist")
    }

    @Test("An album with no year resolves to a nil year, not to zero")
    func nilYear() async throws {
        let (directory, url) = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteLibraryStore(url: url)
        try await store.upsert([makeTrack("Untitled", year: nil)])

        let key = Album.Key(albumArtist: "Vera Lindqvist",
                            title: "Sound of the Slow Hours", year: nil)
        let resolved = try #require(try await store.albumKey(forStableID: key.stableID))
        #expect(resolved.year == nil)
        #expect(try await store.album(for: resolved)?.tracks.count == 1)
    }

    @Test("An id the library never issued resolves to nothing")
    func unknown() async throws {
        let (directory, url) = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteLibraryStore(url: url)
        try await store.upsert([makeTrack("Slow Hours")])

        #expect(try await store.albumKey(forStableID: "al-00000000000000000000000000000000") == nil)
        #expect(try await store.artistName(forStableID: "../../etc/passwd") == nil)
    }

    @Test("Upserting the same tracks again keeps every id")
    func rescanKeepsIDs() async throws {
        let (directory, url) = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteLibraryStore(url: url)
        let track = makeTrack("Slow Hours")
        try await store.upsert([track])
        let album = try #require(try await store.albums().first)
        let before = (album.stableID, album.tracks[0].id)

        // A rescan hands over a freshly read track: same path, new UUID.
        var reread = makeTrack("Slow Hours")
        reread.genre = "Ambient"
        try await store.upsert([reread])

        let after = try #require(try await store.albums().first)
        #expect(after.stableID == before.0)
        #expect(after.tracks[0].id == before.1)
        #expect(try await store.albumKey(forStableID: before.0) == album.key)
    }

    @Test("A library from before the migration gets ids for what it already holds")
    func backfill() async throws {
        let (directory, url) = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A database at the schema just before `v15-stable-ids`, with two
        // albums by one artist already in it.
        do {
            let queue = try DatabaseQueue(path: url.path,
                                          configuration: Migrations.configuration())
            try Migrations.migrator.migrate(queue, upTo: "v14-memories")
            try await queue.write { db in
                for track in [makeTrack("Slow Hours"),
                              makeTrack("First Light", album: "Early Works", year: nil)] {
                    try TrackRecord(track, fileSize: 0).save(db)
                }
            }
        }

        let store = try SQLiteLibraryStore(url: url)
        let early = Album.Key(albumArtist: "Vera Lindqvist", title: "Early Works", year: nil)
        let slow = Album.Key(albumArtist: "Vera Lindqvist",
                             title: "Sound of the Slow Hours", year: 2023)
        #expect(try await store.albumKey(forStableID: early.stableID) == early)
        #expect(try await store.albumKey(forStableID: slow.stableID) == slow)
        #expect(try await store.artistName(
            forStableID: StableID.artist(named: "Vera Lindqvist")) == "Vera Lindqvist")
    }
}
