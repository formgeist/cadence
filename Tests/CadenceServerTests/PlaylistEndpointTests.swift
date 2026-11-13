import Testing
import Foundation
import CadenceCore
import CadenceLibrary
import CadenceServer

private func track(_ title: String, album: String = "Sound of the Slow Hours",
                   seconds: TimeInterval = 100, artwork: String? = nil) -> Track {
    Track(url: URL(fileURLWithPath: "/Volumes/secret-folder/\(album)/\(title).flac"),
          title: title, artist: "Vera Lindqvist", albumTitle: album, duration: seconds,
          artworkID: artwork)
}

private func titles(_ items: Any?) -> [String] {
    (items as? [[String: Any]] ?? []).compactMap { ($0["title"] ?? $0["name"]) as? String }
}

/// Three tracks, two playlists and some likes.
private struct Fixture {
    let library: TestLibrary
    let server: TestServer
    let tracks: [Track]
    let evening: Playlist
    let empty: Playlist

    init() async throws {
        tracks = [track("Morning Static", seconds: 100, artwork: "aa11"),
                  track("Slow Hours", seconds: 200),
                  track("First Light", album: "Early Works", seconds: 300)]
        library = try await TestLibrary(tracks)
        evening = try await library.store.createPlaylist(named: "Evening")
        // The same song twice, and not in library order.
        try await library.store.addTracks(
            [tracks[2].id, tracks[0].id, tracks[2].id], to: evening.id)
        empty = try await library.store.createPlaylist(named: "Nothing Yet")
        server = library.server()
    }

    func wireID(_ playlist: Playlist) -> String { "pl-" + playlist.id.uuidString.lowercased() }
}

@Suite("Playlist endpoints")
struct PlaylistEndpointTests {

    @Test("Playlists are listed with their counts and lengths")
    func list() async throws {
        let fixture = try await Fixture()
        let list = try #require(await fixture.server.get("getPlaylists")
            .object("playlists")["playlist"] as? [[String: Any]])
        #expect(titles(list) == ["Evening", "Nothing Yet"])

        let evening = list[0]
        #expect(evening["id"] as? String == fixture.wireID(fixture.evening))
        #expect(evening["songCount"] as? Int == 3)
        #expect(evening["duration"] as? Int == 700)
        #expect(evening["entry"] == nil)
        #expect(list[1]["songCount"] as? Int == 0)
    }

    @Test("A playlist carries its songs in its own order, repeats included")
    func playlist() async throws {
        let fixture = try await Fixture()
        let playlist = await fixture.server.get(
            "getPlaylist", [("id", fixture.wireID(fixture.evening))]).object("playlist")
        #expect(playlist["name"] as? String == "Evening")
        #expect(playlist["songCount"] as? Int == 3)
        #expect(playlist["duration"] as? Int == 700)
        #expect(titles(playlist["entry"]) == ["First Light", "Morning Static", "First Light"])
        // No cover of its own, so the first song that has one lends its.
        #expect(playlist["coverArt"] as? String == "aa11")
    }

    @Test("A cover the user chose for a playlist wins")
    func customCover() async throws {
        let fixture = try await Fixture()
        try await fixture.library.store.setPlaylistImage("cc33", forPlaylist: fixture.evening.id)
        let playlist = await fixture.server.get(
            "getPlaylist", [("id", fixture.wireID(fixture.evening))]).object("playlist")
        #expect(playlist["coverArt"] as? String == "cc33")
    }

    @Test("An empty playlist is a playlist with no songs, not an error")
    func emptyPlaylist() async throws {
        let fixture = try await Fixture()
        let response = await fixture.server.get(
            "getPlaylist", [("id", fixture.wireID(fixture.empty))])
        #expect(response.isOK)
        #expect(titles(response.object("playlist")["entry"]).isEmpty)
        #expect(response.object("playlist")["songCount"] as? Int == 0)
    }

    @Test("A song removed from the library leaves the playlist it was in")
    func removedTrack() async throws {
        let fixture = try await Fixture()
        try await fixture.library.store.remove(trackIDs: [fixture.tracks[2].id])
        let playlist = await fixture.server.get(
            "getPlaylist", [("id", fixture.wireID(fixture.evening))]).object("playlist")
        #expect(titles(playlist["entry"]) == ["Morning Static"])
        #expect(playlist["songCount"] as? Int == 1)
        #expect(playlist["duration"] as? Int == 100)
    }

    @Test("Only a playlist id finds a playlist", arguments: [
        "nonsense", "pl-", "pl-not-a-uuid", "pl-00000000-0000-0000-0000-000000000000",
        "../../etc/passwd", "'; DROP TABLE playlist; --", "*", "Evening",
    ])
    func unknownIDs(id: String) async throws {
        let fixture = try await Fixture()
        #expect(await fixture.server.get("getPlaylist", [("id", id)]).errorCode == 70)
    }

    @Test("Ids of other kinds, and a playlist id in the wrong case, find nothing")
    func crossKind() async throws {
        let fixture = try await Fixture()
        let server = fixture.server
        let song = "tr-" + fixture.tracks[0].id.uuidString.lowercased()
        #expect(await server.get("getPlaylist", [("id", song)]).errorCode == 70)
        #expect(await server.get("getSong", [("id", fixture.wireID(fixture.evening))]).errorCode == 70)
        #expect(await server.get("stream", [("id", fixture.wireID(fixture.evening))]).errorCode == 70)
        #expect(await server.get(
            "getPlaylist", [("id", "pl-" + fixture.evening.id.uuidString)]).errorCode == 70)
        #expect(await server.get("getPlaylist").errorCode == 10)
    }

    @Test("Reading playlists changes nothing")
    func readOnly() async throws {
        let fixture = try await Fixture()
        let before = try await fixture.library.store.playlists()
        for _ in 0..<3 {
            _ = await fixture.server.get("getPlaylists")
            _ = await fixture.server.get("getPlaylist", [("id", fixture.wireID(fixture.evening))])
            _ = await fixture.server.get("getStarred2")
        }
        #expect(try await fixture.library.store.playlists() == before)
        #expect(try await fixture.library.store.likedTrackIDs().isEmpty)
    }

    // MARK: getStarred2

    @Test("Liked Songs come back most recently liked first, each with when")
    func starred() async throws {
        let fixture = try await Fixture()
        let store = fixture.library.store
        try await store.setLiked(true, trackIDs: [fixture.tracks[1].id])
        try await Task.sleep(for: .milliseconds(20))
        try await store.setLiked(true, trackIDs: [fixture.tracks[0].id])

        let starred = await fixture.server.get("getStarred2").object("starred2")
        #expect(titles(starred["song"]) == ["Morning Static", "Slow Hours"])
        #expect((starred["artist"] as? [Any])?.isEmpty == true)
        #expect((starred["album"] as? [Any])?.isEmpty == true)

        let songs = try #require(starred["song"] as? [[String: Any]])
        let stamp = try #require(songs[0]["starred"] as? String)
        #expect(try Date(stamp, strategy: .iso8601) > Date().addingTimeInterval(-60))
    }

    @Test("With nothing liked, starred is three empty lists")
    func nothingStarred() async throws {
        let fixture = try await Fixture()
        let response = await fixture.server.get("getStarred2")
        #expect(response.isOK)
        #expect(titles(response.object("starred2")["song"]).isEmpty)
    }

    @Test("An unliked song leaves the list")
    func unliked() async throws {
        let fixture = try await Fixture()
        let store = fixture.library.store
        try await store.setLiked(true, trackIDs: fixture.tracks.map(\.id))
        try await store.setLiked(false, trackIDs: [fixture.tracks[1].id])
        let starred = await fixture.server.get("getStarred2").object("starred2")
        #expect(Set(titles(starred["song"])) == ["Morning Static", "First Light"])
    }

    @Test("A song is marked starred only where the answer is about likes")
    func starredOnlyInStarred() async throws {
        let fixture = try await Fixture()
        try await fixture.library.store.setLiked(true, trackIDs: [fixture.tracks[0].id])
        let song = await fixture.server.get(
            "getSong", [("id", "tr-" + fixture.tracks[0].id.uuidString.lowercased())]).object("song")
        #expect(song["starred"] == nil)
    }

    // MARK: Across the three

    @Test("Playlists and starred need a key, and say nothing about paths",
          arguments: ["getPlaylists", "getPlaylist", "getStarred2"])
    func keyAndPaths(endpoint: String) async throws {
        let fixture = try await Fixture()
        try await fixture.library.store.setLiked(true, trackIDs: fixture.tracks.map(\.id))
        let query = [("id", fixture.wireID(fixture.evening))]
        #expect(await fixture.server.get(endpoint, query, authenticated: false).errorCode == 44)

        let response = await fixture.server.get(endpoint, query)
        #expect(response.isOK)
        #expect(!response.text.contains("secret-folder"))
        #expect(!response.text.contains("\"path\""))
    }
}
