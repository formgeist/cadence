import Testing
import Foundation
import CadenceCore
import CadenceLibrary
@testable import CadenceServer

private actor ChangeLog {
    private(set) var changes: [LibraryChange] = []
    func append(_ change: LibraryChange) { changes.append(change) }
}

private struct Fixture {
    let library: TestLibrary
    let tools: LibraryWriteTools
    let log = ChangeLog()
    let tracks: [Track]
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    var store: SQLiteLibraryStore { library.store }

    init() async throws {
        tracks = (1...4).map { number in
            Track(url: URL(fileURLWithPath: "/music/\(number).flac"), title: "Song \(number)",
                  artist: "Band", albumTitle: number <= 2 ? "First" : "Second",
                  genre: "Rock", year: number <= 2 ? 1991 : 1995, label: "Indie", trackNumber: number,
                  duration: 200)
        }
        library = try await TestLibrary(tracks)
        let log = log
        tools = LibraryWriteTools(library: library.store, now: { Fixture.now }) { change in
            await log.append(change)
        }
    }

    func ids(_ indices: Int...) -> JSONValue {
        .array(indices.map { .string(tracks[$0].id.uuidString) })
    }

    @discardableResult
    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let result = try await tools.call(name, arguments: arguments)
        #expect(!result.isError, "\(result.text)")
        return result
    }

    func failure(_ name: String, _ arguments: [String: JSONValue]) async -> String? {
        do {
            let result = try await tools.call(name, arguments: arguments)
            return result.isError ? result.text : nil
        } catch let error as MCPToolError {
            return error.message
        } catch {
            return "unexpected: \(error)"
        }
    }

    func playlist(named name: String) async throws -> Playlist {
        try #require(try await store.playlists().first { $0.name == name })
    }
}

@Suite("MCP library write tools")
struct LibraryWriteToolsTests {

    @Test("Every schema is closed, names are unique, and deletes are marked destructive")
    func schemas() async throws {
        let fixture = try await Fixture()
        let tools = fixture.tools.tools
        #expect(Set(tools.map(\.name)).count == tools.count)
        for tool in tools {
            #expect(tool.inputSchema["additionalProperties"] == false, "\(tool.name)")
            #expect(!tool.annotations.readOnly, "\(tool.name)")
            #expect(tool.annotations.destructive == tool.name.hasPrefix("delete_")
                    || tool.name == "remove_tracks_from_playlist", "\(tool.name)")
        }
        // Nothing reaches outside playlists, folders, catalogs, memories and likes.
        let names = Set(tools.map(\.name))
        #expect(!names.contains { $0.contains("library") || $0.contains("folder_scan") })
    }

    // MARK: Playlists

    @Test("create_playlist makes it with tracks in order and reports the change")
    func createPlaylist() async throws {
        let fixture = try await Fixture()
        let result = try await fixture.call("create_playlist",
                                            ["name": "Drive", "trackIDs": fixture.ids(2, 0, 2)])
        #expect(result.structured?["name"] == "Drive")
        #expect(result.structured?["trackCount"] == 3)
        let playlist = try await fixture.playlist(named: "Drive")
        #expect(playlist.trackIDs == [fixture.tracks[2].id, fixture.tracks[0].id, fixture.tracks[2].id])
        let changes = await fixture.log.changes
        #expect(changes == [LibraryChange([.playlists], "Created the playlist “Drive”")])
    }

    @Test("create_playlist can file it in a folder")
    func createInFolder() async throws {
        let fixture = try await Fixture()
        let folder = try await fixture.call("create_playlist_folder", ["name": "Moods"])
        let folderID = try #require(folder.structured?["id"])
        try await fixture.call("create_playlist", ["name": "Calm", "folderID": folderID])
        #expect(try await fixture.playlist(named: "Calm").folderID?.uuidString == folderID.stringValue)
    }

    @Test("An unknown track id fails the whole call and changes nothing")
    func unknownTrack() async throws {
        let fixture = try await Fixture()
        let missing = UUID().uuidString
        let failure = await fixture.failure(
            "create_playlist",
            ["name": "Half", "trackIDs": [.string(fixture.tracks[0].id.uuidString), .string(missing)]])
        #expect(failure == "1 track not in the library: \(missing). Nothing was changed.")
        #expect(try await fixture.store.playlists().isEmpty)
        #expect(await fixture.log.changes.isEmpty)
    }

    @Test("Names are required, bounded and stripped of control characters")
    func names() async throws {
        let fixture = try await Fixture()
        #expect(await fixture.failure("create_playlist", ["name": "   "]) == "“name” is required.")
        #expect(await fixture.failure("create_playlist", ["name": .string(String(repeating: "a", count: 201))])
                == "“name” is at most 200 characters.")
        try await fixture.call("create_playlist", ["name": "Line\none"])
        _ = try await fixture.playlist(named: "Lineone")
    }

    @Test("Adding, removing by position and moving edit the playlist as get_playlist numbers it")
    func editPlaylist() async throws {
        let fixture = try await Fixture()
        try await fixture.call("create_playlist", ["name": "Mix", "trackIDs": fixture.ids(0, 1)])
        let id = JSONValue.string(try await fixture.playlist(named: "Mix").id.uuidString)

        try await fixture.call("add_tracks_to_playlist", ["playlistID": id, "trackIDs": fixture.ids(2, 3)])
        #expect(try await fixture.playlist(named: "Mix").trackIDs == fixture.tracks.map(\.id))

        // Positions 3 and 0 go before what is now at 2: [1, 3, 0, 2]... in their own order.
        try await fixture.call("move_tracks_in_playlist",
                               ["playlistID": id, "positions": [3, 0], "toPosition": 2])
        #expect(try await fixture.playlist(named: "Mix").trackIDs
                == [1, 0, 3, 2].map { fixture.tracks[$0].id })

        try await fixture.call("remove_tracks_from_playlist", ["playlistID": id, "positions": [0, 3]])
        #expect(try await fixture.playlist(named: "Mix").trackIDs
                == [0, 3].map { fixture.tracks[$0].id })
        // The tracks themselves stay.
        #expect(try await fixture.store.allTracks().count == 4)
    }

    @Test("A position past the end is refused with the range")
    func badPosition() async throws {
        let fixture = try await Fixture()
        try await fixture.call("create_playlist", ["name": "Two", "trackIDs": fixture.ids(0, 1)])
        let id = JSONValue.string(try await fixture.playlist(named: "Two").id.uuidString)
        #expect(await fixture.failure("remove_tracks_from_playlist", ["playlistID": id, "positions": [2]])
                == "“Two” has 2 tracks; positions run from 0 to 1.")
        #expect(await fixture.failure("move_tracks_in_playlist",
                                      ["playlistID": id, "positions": [0], "toPosition": 3])
                == "“toPosition” must be between 0 and 2.")
    }

    @Test("Rename and delete take ids, and an unknown id is named")
    func renameAndDelete() async throws {
        let fixture = try await Fixture()
        try await fixture.call("create_playlist", ["name": "Old"])
        let id = JSONValue.string(try await fixture.playlist(named: "Old").id.uuidString)
        try await fixture.call("rename_playlist", ["playlistID": id, "name": "New"])
        _ = try await fixture.playlist(named: "New")
        try await fixture.call("delete_playlist", ["playlistID": id])
        #expect(try await fixture.store.playlists().isEmpty)
        #expect(await fixture.failure("delete_playlist", ["playlistID": id])?.hasPrefix("No playlist") == true)
        #expect(await fixture.failure("delete_playlist", ["name": "New"]) == "Unknown argument “name”.")
    }

    // MARK: Folders

    @Test("Deleting a folder keeps its playlists at the top level")
    func folders() async throws {
        let fixture = try await Fixture()
        let folder = try await fixture.call("create_playlist_folder", ["name": "Old"])
        let folderID = try #require(folder.structured?["id"])
        try await fixture.call("rename_playlist_folder", ["folderID": folderID, "name": "Archive"])
        #expect(try await fixture.store.playlistFolders().map(\.name) == ["Archive"])

        try await fixture.call("create_playlist", ["name": "Kept"])
        let playlistID = JSONValue.string(try await fixture.playlist(named: "Kept").id.uuidString)
        try await fixture.call("move_playlist_to_folder", ["playlistID": playlistID, "folderID": folderID])
        #expect(try await fixture.playlist(named: "Kept").folderID != nil)

        try await fixture.call("delete_playlist_folder", ["folderID": folderID])
        #expect(try await fixture.store.playlistFolders().isEmpty)
        #expect(try await fixture.playlist(named: "Kept").folderID == nil)
        let last = await fixture.log.changes.last
        #expect(last?.parts == [.folders, .playlists])
    }

    // MARK: Catalogs

    @Test("save_catalog creates, then replaces by id, and counts albums")
    func catalogs() async throws {
        let fixture = try await Fixture()
        let created = try await fixture.call("save_catalog", [
            "name": "Early",
            "definition": ["rules": [["field": "year", "op": "before", "number": 1993]]],
        ])
        #expect(created.structured?["albumCount"] == 1)
        let id = try #require(created.structured?["id"])

        let changed = try await fixture.call("save_catalog", [
            "catalogID": id, "name": "Indie",
            "definition": ["rules": [["field": "label", "op": "is", "text": "Indie"]], "sort": "title"],
        ])
        #expect(changed.structured?["albumCount"] == 2)
        let stored = try await fixture.store.catalogs()
        #expect(stored.map(\.name) == ["Indie"])
        #expect(stored.first?.definition.sort == .title)
        #expect(stored.first?.createdAt == Fixture.now)

        try await fixture.call("delete_catalog", ["catalogID": id])
        #expect(try await fixture.store.catalogs().isEmpty)
    }

    // MARK: Memories

    @Test("A memory goes on an album or a song, and its text can change")
    func memories() async throws {
        let fixture = try await Fixture()
        let onAlbum = try await fixture.call("save_memory", [
            "albumID": .string(fixture.tracks[0].albumKey.stableID), "text": "  First gig.  ",
        ])
        #expect(onAlbum.structured?["text"] == "First gig.")
        let onSong = try await fixture.call("save_memory", [
            "trackID": .string(fixture.tracks[3].id.uuidString), "text": "The encore.",
        ])
        #expect(onSong.structured?["trackTitle"] == "Song 4")

        let id = try #require(onAlbum.structured?["id"])
        try await fixture.call("save_memory", ["memoryID": id, "text": "Second gig, really."])
        let memories = try await fixture.store.memories()
        #expect(Set(memories.map(\.text)) == ["Second gig, really.", "The encore."])

        try await fixture.call("delete_memory", ["memoryID": id])
        #expect(try await fixture.store.memories().map(\.text) == ["The encore."])
    }

    @Test("A memory too long is refused, not cut; and the subject must be one thing")
    func memoryRules() async throws {
        let fixture = try await Fixture()
        let album = JSONValue.string(fixture.tracks[0].albumKey.stableID)
        #expect(await fixture.failure("save_memory", ["albumID": album,
                                                      "text": .string(String(repeating: "x", count: 501))])
                == "A memory is at most 500 characters; this is 501.")
        #expect(await fixture.failure("save_memory", ["text": "Hi"]) == "Give either albumID or trackID.")
        #expect(await fixture.failure("save_memory", [
            "albumID": album, "trackID": .string(fixture.tracks[0].id.uuidString), "text": "Hi",
        ]) == "Give either albumID or trackID.")
        #expect(await fixture.failure("save_memory", ["albumID": "al-nope", "text": "Hi"])?
            .hasPrefix("No album") == true)
        #expect(try await fixture.store.memories().isEmpty)
    }

    // MARK: Likes

    @Test("set_liked likes and unlikes")
    func likes() async throws {
        let fixture = try await Fixture()
        try await fixture.call("set_liked", ["trackIDs": fixture.ids(1, 2), "liked": true])
        #expect(Set(try await fixture.store.likedTrackIDs()) == [fixture.tracks[1].id, fixture.tracks[2].id])
        try await fixture.call("set_liked", ["trackIDs": fixture.ids(1), "liked": false])
        #expect(try await fixture.store.likedTrackIDs() == [fixture.tracks[2].id])
        #expect(await fixture.failure("set_liked", ["trackIDs": fixture.ids(1)]) == "“liked” is required.")
        #expect(await fixture.log.changes.map(\.summary) == ["Liked 2 tracks", "Unliked 1 track"])
    }

    // MARK: Together

    @Test("MCPToolSet offers read and write tools as one, through the server")
    func toolSet() async throws {
        let fixture = try await Fixture()
        let set = MCPToolSet([LibraryTools(library: fixture.store), fixture.tools])
        #expect(set.tools.count == 11 + 15)
        #expect(Set(set.tools.map(\.name)).count == set.tools.count)

        let server = MCPServer(configuration: .init(serverVersion: "1"),
                               authenticator: FixedKeyAuthenticator(key: TestLibrary.key), tools: set)
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_playlist","arguments":{"name":"Via server"}}}"#
        let response = await server.respond(to: HTTPRequest(
            method: .post, path: "/mcp",
            headers: ["content-type": "application/json", "authorization": "Bearer \(TestLibrary.key)"],
            body: Data(body.utf8)))
        #expect(response.status == .ok)
        _ = try await fixture.playlist(named: "Via server")
    }
}
