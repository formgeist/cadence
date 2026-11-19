import Testing
import Foundation
import CadenceCore
import CadenceLibrary
@testable import CadenceServer

/// A small library: two Miles Davis records, one Alice Coltrane, one
/// Kraftwerk, with plays, likes, a playlist, a catalog and a memory.
private struct Fixture {
    let library: TestLibrary
    let tools: LibraryTools
    let kind: [Track]
    let journey: [Track]
    let autobahn: Track
    let playlist: Playlist
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() async throws {
        func track(_ title: String, _ artist: String, _ album: String, year: Int, number: Int,
                   genre: String, label: String, added: TimeInterval = 0) -> Track {
            Track(url: URL(fileURLWithPath: "/music/\(album)/\(number).flac"), title: title,
                  artist: artist, albumTitle: album, genre: genre, year: year, label: label,
                  trackNumber: number, duration: 300,
                  dateAdded: Fixture.now.addingTimeInterval(added))
        }
        kind = [
            track("So What", "Miles Davis", "Kind of Blue", year: 1959, number: 1, genre: "Jazz", label: "Columbia"),
            track("Freddie Freeloader", "Miles Davis", "Kind of Blue", year: 1959, number: 2, genre: "Jazz", label: "Columbia"),
            track("Blue in Green", "Miles Davis", "Kind of Blue", year: 1959, number: 3, genre: "Jazz", label: "Columbia"),
        ]
        let bitches = track("Pharaoh's Dance", "Miles Davis", "Bitches Brew", year: 1970, number: 1,
                            genre: "Jazz Fusion", label: "Columbia", added: -86_400)
        journey = [
            track("Journey in Satchidananda", "Alice Coltrane", "Journey in Satchidananda", year: 1971, number: 1,
                  genre: "Spiritual Jazz", label: "Impulse!", added: -3_600),
            track("Shiva-Loka", "Alice Coltrane", "Journey in Satchidananda", year: 1971, number: 2,
                  genre: "Spiritual Jazz", label: "Impulse!", added: -3_600),
        ]
        autobahn = track("Autobahn", "Kraftwerk", "Autobahn", year: 1974, number: 1,
                         genre: "Electronic", label: "Philips", added: -200_000)
        library = try await TestLibrary(kind + [bitches] + journey + [autobahn])
        let store = library.store

        // Kind of Blue played most, then Journey; one old play outside 30 days.
        for (offset, track) in [kind[0], kind[1], kind[0], journey[0], autobahn].enumerated() {
            try await store.record(PlayRecord(track: track, playedAt: Fixture.now.addingTimeInterval(
                -Double(offset + 1) * 3_600)))
        }
        try await store.record(PlayRecord(track: autobahn,
                                          playedAt: Fixture.now.addingTimeInterval(-60 * 86_400)))
        try await store.setLiked(true, trackIDs: [journey[1].id])

        let created = try await store.createPlaylist(named: "Late night")
        try await store.addTracks([kind[2].id, journey[0].id, kind[2].id], to: created.id)
        playlist = try #require(try await store.playlists().first { $0.id == created.id })

        try await store.saveCatalog(Catalog(name: "Columbia", definition: .init(
            rules: [CatalogRule(field: .label, op: .is, text: "Columbia")])))
        try await store.saveMemory(Memory(subject: .album(kind[0].albumKey),
                                          text: "Bought it in Copenhagen.", createdAt: Fixture.now))

        tools = LibraryTools(library: store, now: { Fixture.now })
    }

    func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let result = try await tools.call(name, arguments: arguments)
        #expect(!result.isError)
        return try #require(result.structured)
    }

    func failure(_ name: String, _ arguments: [String: JSONValue]) async -> String? {
        do {
            let result = try await tools.call(name, arguments: arguments)
            return result.isError ? result.text : nil
        } catch let error as MCPToolError {
            return error.message
        } catch {
            return nil
        }
    }
}

private extension JSONValue {
    func list(_ key: String) -> [JSONValue] { self[key]?.arrayValue ?? [] }
    func strings(_ key: String, _ field: String) -> [String?] { list(key).map { $0[field]?.stringValue } }
}

@Suite("MCP library read tools")
struct LibraryToolsTests {

    @Test("Every tool's schema is a closed object, and every name is unique")
    func schemas() async throws {
        let fixture = try await Fixture()
        let tools = fixture.tools.tools
        #expect(Set(tools.map(\.name)).count == tools.count)
        for tool in tools {
            #expect(tool.inputSchema["type"] == "object", "\(tool.name)")
            #expect(tool.inputSchema["additionalProperties"] == false, "\(tool.name)")
            #expect(tool.annotations.readOnly, "\(tool.name)")
        }
    }

    // MARK: search_tracks

    @Test("A query finds tracks, with album ids and likes")
    func search() async throws {
        let fixture = try await Fixture()
        let result = try await fixture.call("search_tracks", ["query": "satchidananda"])
        #expect(Set(result.strings("tracks", "title"))
                == ["Journey in Satchidananda", "Shiva-Loka"])
        let shiva = try #require(result.list("tracks").first { $0["title"] == "Shiva-Loka" })
        #expect(shiva["liked"] == true)
        #expect(shiva["albumID"]?.stringValue == fixture.journey[0].albumKey.stableID)
        #expect(shiva["id"]?.stringValue == fixture.journey[1].id.uuidString)
        // No paths leave the library.
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!encoded.contains("/music/"))
    }

    @Test("Filters alone list tracks in album order")
    func filtersAlone() async throws {
        let fixture = try await Fixture()
        let result = try await fixture.call("search_tracks", ["artist": "miles", "yearTo": 1965])
        #expect(result.strings("tracks", "title") == ["So What", "Freddie Freeloader", "Blue in Green"])
        let genre = try await fixture.call("search_tracks", ["genre": "spiritual"])
        #expect(genre["total"] == 2)
    }

    @Test("Paging reports the next offset until the end")
    func paging() async throws {
        let fixture = try await Fixture()
        let first = try await fixture.call("search_tracks", ["artist": "Miles", "limit": 2])
        #expect(first.list("tracks").count == 2)
        #expect(first["total"] == 4)
        #expect(first["nextOffset"] == 2)
        let second = try await fixture.call("search_tracks", ["artist": "Miles", "limit": 2, "offset": 2])
        #expect(second.list("tracks").count == 2)
        #expect(second["nextOffset"] == nil)
    }

    @Test("Bad arguments are named back to the model")
    func badArguments() async throws {
        let fixture = try await Fixture()
        #expect(await fixture.failure("search_tracks", [:]) == "Give a query or at least one filter.")
        #expect(await fixture.failure("search_tracks", ["query": "x", "limt": 5])
                == "Unknown argument “limt”.")
        #expect(await fixture.failure("search_tracks", ["query": "x", "limit": 0])
                == "“limit” must be between 1 and 500.")
        #expect(await fixture.failure("search_tracks", ["query": 3]) == "“query” must be a string.")
    }

    // MARK: Artists and albums

    @Test("Artists come with ids that list_albums takes")
    func artistsAndAlbums() async throws {
        let fixture = try await Fixture()
        let artists = try await fixture.call("list_artists")
        #expect(artists.strings("artists", "name") == ["Alice Coltrane", "Kraftwerk", "Miles Davis"])
        let miles = try #require(artists.list("artists").last?["id"]?.stringValue)

        let albums = try await fixture.call("list_albums", ["artistID": .string(miles), "sort": "yearNewest"])
        #expect(albums.strings("albums", "title") == ["Bitches Brew", "Kind of Blue"])
        #expect(await fixture.failure("list_albums", ["artistID": "ar-nope"])?.hasPrefix("No artist") == true)
    }

    @Test("Albums filter by decade and genre, and sort by date added")
    func albumFilters() async throws {
        let fixture = try await Fixture()
        let seventies = try await fixture.call("list_albums", ["decade": 1970, "sort": "yearOldest"])
        #expect(seventies.strings("albums", "title") == ["Bitches Brew", "Journey in Satchidananda", "Autobahn"])
        let jazz = try await fixture.call("list_albums", ["genre": "jazz", "sort": "recentlyAdded"])
        #expect(jazz.strings("albums", "title") == ["Kind of Blue", "Journey in Satchidananda", "Bitches Brew"])
    }

    @Test("get_album has the tracks in order, the label and the memories")
    func getAlbum() async throws {
        let fixture = try await Fixture()
        let album = try await fixture.call("get_album", ["id": .string(fixture.kind[0].albumKey.stableID)])
        #expect(album["title"] == "Kind of Blue")
        #expect(album["label"] == "Columbia")
        #expect(album.strings("tracks", "title") == ["So What", "Freddie Freeloader", "Blue in Green"])
        #expect(album.strings("memories", "text") == ["Bought it in Copenhagen."])
        #expect(await fixture.failure("get_album", ["id": "al-missing"])?.hasPrefix("No album") == true)
    }

    // MARK: History and likes

    @Test("History groups the last 30 days by album, most played first")
    func historyByAlbum() async throws {
        let fixture = try await Fixture()
        let history = try await fixture.call("listening_history")
        #expect(history["playCount"] == 5)
        #expect(history.strings("groups", "album") == ["Kind of Blue", "Journey in Satchidananda", "Autobahn"])
        #expect(history.list("groups").first?["plays"] == 3)
    }

    @Test("History by track resolves songs to track ids; by play lists newest first")
    func historyByTrack() async throws {
        let fixture = try await Fixture()
        let tracks = try await fixture.call("listening_history", ["groupBy": "track"])
        let top = try #require(tracks.list("groups").first)
        #expect(top["title"] == "So What")
        #expect(top["trackID"]?.stringValue == fixture.kind[0].id.uuidString)

        let plays = try await fixture.call("listening_history", ["groupBy": "play", "limit": 2])
        #expect(plays.strings("plays", "title") == ["So What", "Freddie Freeloader"])
    }

    @Test("A wider window takes in older plays")
    func historyWindow() async throws {
        let fixture = try await Fixture()
        let all = try await fixture.call("listening_history", ["from": "2020-01-01", "groupBy": "artist"])
        #expect(all["playCount"] == 6)
        let kraftwerk = try #require(all.list("groups").first { $0["artist"] == "Kraftwerk" })
        #expect(kraftwerk["plays"] == 2)
        #expect(await fixture.failure("listening_history", ["from": "last week"])?.contains("ISO 8601") == true)
    }

    @Test("Liked songs come with when they were liked")
    func liked() async throws {
        let fixture = try await Fixture()
        let liked = try await fixture.call("liked_tracks")
        #expect(liked.strings("tracks", "title") == ["Shiva-Loka"])
        #expect(liked.list("tracks").first?["likedAt"] != nil)
    }

    // MARK: Playlists

    @Test("Playlists list, and a playlist's tracks carry their positions")
    func playlists() async throws {
        let fixture = try await Fixture()
        let all = try await fixture.call("list_playlists")
        #expect(all.strings("playlists", "name") == ["Late night"])
        #expect(all.list("playlists").first?["trackCount"] == 3)

        let playlist = try await fixture.call("get_playlist", ["id": .string(fixture.playlist.id.uuidString)])
        #expect(playlist.strings("tracks", "title") == ["Blue in Green", "Journey in Satchidananda", "Blue in Green"])
        #expect(playlist.list("tracks").map { $0["position"] } == [0, 1, 2])

        let page = try await fixture.call("get_playlist", ["id": .string(fixture.playlist.id.uuidString),
                                                           "offset": 1, "limit": 1])
        #expect(page.list("tracks").map { $0["position"] } == [1])
        #expect(await fixture.failure("get_playlist", ["id": .string(UUID().uuidString)])?
            .hasPrefix("No playlist") == true)
        #expect(await fixture.failure("get_playlist", ["id": "nope"]) == "“id” is not a valid id.")
    }

    // MARK: Catalogs

    @Test("Catalogs list with their rules and current album count")
    func catalogs() async throws {
        let fixture = try await Fixture()
        let result = try await fixture.call("list_catalogs")
        let catalog = try #require(result.list("catalogs").first)
        #expect(catalog["name"] == "Columbia")
        #expect(catalog["albumCount"] == 2)
        #expect(catalog["definition"]?["summary"] == "Label is Columbia")
    }

    @Test("preview_catalog matches albums without saving")
    func preview() async throws {
        let fixture = try await Fixture()
        let result = try await fixture.call("preview_catalog", ["definition": [
            "match": "any",
            "sort": "yearOldest",
            "rules": [["field": "label", "op": "is", "text": "Impulse!"],
                      ["field": "decade", "op": "is", "number": 1950]],
        ]])
        #expect(result.strings("albums", "title") == ["Kind of Blue", "Journey in Satchidananda"])
        #expect(result["definition"]?["summary"] == "Label is Impulse! or Decade is 1950s")
        #expect(try await fixture.library.store.catalogs().count == 1)
    }

    static let badCatalogs: [(JSONValue, String)] = [
        (["rules": []], "“rules” must be a list with at least one rule."),
        (["rules": [["field": "mood", "op": "is", "text": "x"]]], "Rule 1: “field” must be one of"),
        (["rules": [["field": "year", "op": "contains", "number": 1970]]], "Rule 1: “op” for year must be one of: is, between, before, after."),
        (["rules": [["field": "year", "op": "between", "number": 1970]]], "Rule 1: It is missing the value year between needs."),
        (["rules": [["field": "label", "op": "is", "text": "ECM", "id": "x"]]], "Rule 1: Unknown argument “id”."),
    ]

    @Test("A catalog rule an agent got wrong is explained", arguments: badCatalogs)
    func badCatalog(definition: JSONValue, message: String) async throws {
        let fixture = try await Fixture()
        let failure = try #require(await fixture.failure("preview_catalog", ["definition": definition]))
        #expect(failure.hasPrefix(message), "\(failure)")
    }

    // MARK: Memories

    @Test("Memories list, filtered by album")
    func memories() async throws {
        let fixture = try await Fixture()
        let all = try await fixture.call("list_memories")
        #expect(all.strings("memories", "text") == ["Bought it in Copenhagen."])
        let other = try await fixture.call("list_memories",
                                           ["albumID": .string(fixture.autobahn.albumKey.stableID)])
        #expect(other["total"] == 0)
    }

    // MARK: Through the server

    @Test("The tools work through MCPServer, and the list encodes")
    func throughServer() async throws {
        let fixture = try await Fixture()
        let server = MCPServer(
            configuration: .init(serverVersion: "1", instructions: LibraryTools.instructions),
            authenticator: FixedKeyAuthenticator(key: TestLibrary.key), tools: fixture.tools)
        func post(_ body: String) async throws -> [String: Any] {
            let response = await server.respond(to: HTTPRequest(
                method: .post, path: "/mcp",
                headers: ["content-type": "application/json",
                          "authorization": "Bearer \(TestLibrary.key)"],
                body: Data(body.utf8)))
            return try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        }
        let list = try await post(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 11)

        let call = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_artists","arguments":{"limit":1}}}"#)
        let result = try #require(call["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect((result["content"] as? [[String: Any]])?.first?["text"] as? String == "1 of 3 artists, from 0.")
    }
}
