import Testing
import Foundation
import CadenceCore
import CadenceLibrary
@testable import CadenceServer
@testable import CadenceRemote

@Suite("Another Mac's library as a LibraryStore", .serialized)
struct RemoteLibraryStoreTests {

    /// Adds a compilation to the server's library: two tracks whose
    /// performers differ from the album artist.
    private func addCompilation(to server: LiveServer) async throws {
        try await server.store.upsert([
            Track(url: server.directory.appendingPathComponent("c1.flac"),
                  title: "Opening", artist: "Ada Moss", albumArtist: "Various Artists",
                  albumTitle: "Night Tapes", year: 2021, trackNumber: 1, discNumber: 1,
                  duration: 180, format: .cd),
            Track(url: server.directory.appendingPathComponent("c2.mp3"),
                  title: "Closing", artist: "Ben Hale", albumArtist: "Various Artists",
                  albumTitle: "Night Tapes", year: 2021, trackNumber: 2, discNumber: 1,
                  duration: 190, format: AudioFormat(codec: .mp3, sampleRate: 44_100,
                                                     bitDepth: nil, channelCount: 2,
                                                     bitRate: 320)),
        ])
    }

    @Test("Every track arrives, across pages, with the Mac's ids and album artists")
    func listing() async throws {
        try await withServer { server in
            try await addCompilation(to: server)
            // Pages of one, so four tracks take five requests.
            let store = RemoteLibraryStore(client: try await server.pair(), pageSize: 1)

            let tracks = try await store.allTracks()
            let macTracks = try await server.store.allTracks()
            #expect(Set(tracks.map(\.id)) == Set(macTracks.map(\.id)))

            // A compilation track names the album artist, not its performer,
            // so the album holds together.
            let opening = try #require(tracks.first { $0.title == "Opening" })
            #expect(opening.artist == "Ada Moss")
            #expect(opening.albumArtist == "Various Artists")

            let albums = try await store.albums()
            #expect(Set(albums.map(\.key)) == Set(Album.grouped(from: macTracks).map(\.key)))
            let tapes = try #require(albums.first { $0.title == "Night Tapes" })
            #expect(tapes.tracks.map(\.title) == ["Opening", "Closing"])
            #expect(try await store.album(for: tapes.key)?.tracks.count == 2)
            #expect(try await store.albums(byArtist: "Various Artists").map(\.title) == ["Night Tapes"])
        }
    }

    @Test("Artists are worked out as the Mac's own store works them out")
    func artists() async throws {
        try await withServer { server in
            try await addCompilation(to: server)
            let store = RemoteLibraryStore(client: try await server.pair())
            #expect(try await store.artists() == (try await server.store.artists()))
        }
    }

    @Test("Playlists come with their tracks, and likes in the Mac's order")
    func playlistsAndLikes() async throws {
        try await withServer { server in
            let mac = try await server.store.allTracks()
            let playlist = try await server.store.createPlaylist(named: "Evening")
            try await server.store.addTracks([mac[1].id, mac[0].id, mac[1].id], to: playlist.id)
            try await server.store.setLiked(true, trackIDs: [mac[0].id])
            try await server.store.setLiked(true, trackIDs: [mac[1].id])

            let store = RemoteLibraryStore(client: try await server.pair())
            let playlists = try await store.playlists()
            #expect(playlists.map(\.id) == [playlist.id])
            #expect(playlists.first?.trackIDs == [mac[1].id, mac[0].id, mac[1].id])
            #expect(try await store.likedTrackIDs() == (try await server.store.likedTrackIDs()))
        }
    }

    @Test("Search answers with the listing's tracks")
    func search() async throws {
        try await withServer { server in
            try await addCompilation(to: server)
            let store = RemoteLibraryStore(client: try await server.pair())
            let tracks = try await store.allTracks()
            let hits = try await store.tracks(matching: "Opening")
            #expect(hits.map(\.title) == ["Opening"])
            #expect(hits.first == tracks.first { $0.title == "Opening" })
            #expect(try await store.tracks(matching: "  ").isEmpty)
        }
    }

    @Test("With the Mac gone, the library it last sent is still there")
    func offline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-remote-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withServer { server in
            let client = try await server.pair(cache: RemoteMetadataCache(directory: directory))
            let mac = try await server.store.allTracks()
            try await server.store.setLiked(true, trackIDs: [mac[0].id])

            let online = RemoteLibraryStore(client: client)
            let tracks = try await online.allTracks()
            let playlists = try await online.playlists()
            let likes = try await online.likedTrackIDs()

            server.listener.stop()

            // A fresh store, as after a relaunch.
            let offline = RemoteLibraryStore(client: client)
            #expect(try await offline.allTracks() == tracks)
            #expect(try await offline.playlists() == playlists)
            #expect(try await offline.likedTrackIDs() == likes)
        }
    }

    @Test("Nothing cached and no Mac is the network's error, not the cache's")
    func offlineWithoutCache() async throws {
        try await withServer { server in
            let store = RemoteLibraryStore(client: try await server.pair())
            server.listener.stop()
            await expectError(.unreachable) { _ = try await store.allTracks() }
        }
    }

    @Test("Every change is refused without asking the Mac")
    func readOnly() async throws {
        try await withServer { server in
            let store = RemoteLibraryStore(client: try await server.pair())
            let id = try #require(try await server.store.allTracks().first?.id)
            await expectError(.readOnly) { _ = try await store.createPlaylist(named: "New") }
            await expectError(.readOnly) { try await store.setLiked(true, trackIDs: [id]) }
            await expectError(.readOnly) { try await store.remove(trackIDs: [id]) }
            await expectError(.readOnly) { try await store.upsert([]) }
            #expect(try await server.store.likedTrackIDs().isEmpty)
            #expect(try await server.store.playlists().isEmpty)
        }
    }
}

@Suite("Another Mac's covers as an ArtworkStore", .serialized)
struct RemoteArtworkStoreTests {

    @Test("A cover is fetched once, kept, and still there without the Mac")
    func cover() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-remote-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withServer { server in
            // A PNG signature is all the server checks before sending a cover.
            let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                + Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            let id = try await server.artwork.store(bytes)
            let covers = RemoteArtworkStore(client: try await server.pair(), directory: directory)

            let fetched = try await covers.full(for: id)
            #expect(fetched == bytes)

            server.listener.stop()
            #expect(try await covers.full(for: id) == bytes)
            // Neither cached nor reachable: a placeholder, not an error.
            #expect(try await covers.full(for: String(repeating: "a", count: 64)) == nil)

            // The id is not a file name.
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names.count == 1)
            #expect(!names.contains { $0.contains(id) })

            await expectError(.readOnly) { _ = try await covers.store(bytes) }
        }
    }

    @Test("A cover the Mac does not have is a placeholder")
    func missing() async throws {
        try await withServer { server in
            let covers = RemoteArtworkStore(
                client: try await server.pair(),
                directory: server.directory.appendingPathComponent("client-art"))
            #expect(try await covers.full(for: String(repeating: "b", count: 64)) == nil)
        }
    }
}

@Suite("Remote store listing fetch", .serialized)
struct RemoteListingSharingTests {

    @Test("Tracks and artists asked for at once both answer")
    func sharedListing() async throws {
        try await withServer { server in
            // Pages of one, so the listing spans several requests while the
            // second caller waits on it.
            let store = RemoteLibraryStore(client: try await server.pair(), pageSize: 1)
            async let tracks = store.allTracks()
            async let artists = store.artists()
            let (listed, named) = try await (tracks, artists)
            #expect(listed.count == 2)
            #expect(named.map(\.name) == ["Vera Lindqvist"])
        }
    }
}
