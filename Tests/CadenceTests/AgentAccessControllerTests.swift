import Testing
import Foundation
import CadenceCore
import CadenceLibrary
import CadenceServer
@testable import Cadence

/// The app's side of agent access: the switch, the key, the listener, and an
/// agent's edit reaching the window.
@Suite("Agent access", .serialized)
@MainActor
struct AgentAccessControllerTests {

    /// A library on a temporary database, the model over it, and a
    /// controller on a port the system picks.
    @MainActor
    private final class Harness {
        let directory: URL
        let store: SQLiteLibraryStore
        let model: AppModel
        let settings = InMemorySettingsStore()
        let keychain = InMemoryKeychainStore()
        let controller: AgentAccessController
        let track: Track

        init(port: UInt16? = nil) async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cadence-agents-\(UUID().uuidString)")
            store = try SQLiteLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            track = Track(url: URL(fileURLWithPath: "/music/a.flac"), title: "Aerial",
                          artist: "Band", albumTitle: "Sky", year: 2001, duration: 180)
            try await store.upsert([track])
            model = AppModel(store: store, settings: settings, memories: store)
            await model.load()
            controller = AgentAccessController(library: store, model: model, settings: settings,
                                               keychain: keychain, port: port, serverVersion: "test")
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func start() async throws -> URL {
            controller.setEnabled(true)
            await controller.settle()
            return try #require(controller.endpointURL.flatMap(URL.init(string:)))
        }
    }

    private struct Reply {
        var status: Int
        var json: [String: Any]?
    }

    private func post(_ url: URL, key: String, _ body: String) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                     json: try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func callTool(_ url: URL, key: String, _ name: String, _ arguments: String) async throws
        -> [String: Any] {
        let reply = try await post(url, key: key, #"""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}
            """#)
        #expect(reply.status == 200)
        let result = try #require(reply.json?["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false, "\(result)")
        return result
    }

    private let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#

    // MARK: The switch

    @Test("Off until asked: building and resuming with the setting off start nothing")
    func offByDefault() async throws {
        let harness = try await Harness()
        harness.controller.resumeIfEnabled()
        await harness.controller.settle()
        #expect(harness.controller.status == .off)
        #expect(harness.controller.endpointURL == nil)
    }

    @Test("On serves the endpoint with the key; off stops it and is remembered")
    func onAndOff() async throws {
        let harness = try await Harness()
        let url = try await harness.start()
        #expect(url.host == "127.0.0.1")
        #expect(url.path == "/mcp")
        #expect(harness.settings.bool(forKey: .agentAccessEnabled) == true)

        #expect(try await post(url, key: harness.controller.key(), ping).status == 200)
        #expect(try await post(url, key: "wrong", ping).status == 401)

        harness.controller.setEnabled(false)
        await harness.controller.settle()
        #expect(harness.controller.status == .off)
        #expect(harness.settings.bool(forKey: .agentAccessEnabled) == false)
        await #expect(throws: (any Error).self) {
            _ = try await self.post(url, key: harness.controller.key(), self.ping)
        }
    }

    @Test("A launch with the setting on starts it")
    func resumes() async throws {
        let harness = try await Harness()
        harness.settings.set(true, forKey: .agentAccessEnabled)
        let controller = AgentAccessController(
            library: harness.store, model: harness.model, settings: harness.settings,
            keychain: harness.keychain, port: nil, serverVersion: "test")
        controller.resumeIfEnabled()
        await controller.settle()
        #expect(controller.endpointURL != nil)
        controller.shutDown()
    }

    // MARK: The key

    @Test("The key is made once, kept in the keychain, and long")
    func key() async throws {
        let harness = try await Harness()
        let key = harness.controller.key()
        #expect(key.count >= 43)
        #expect(harness.controller.key() == key)
        #expect(harness.keychain.string(forAccount: AgentAccessController.keychainAccount) == key)
        #expect(!key.contains("+") && !key.contains("/") && !key.contains("="))
    }

    @Test("A new key locks out the old one at once")
    func regenerate() async throws {
        let harness = try await Harness()
        let url = try await harness.start()
        let old = harness.controller.key()
        harness.controller.regenerateKey()
        await harness.controller.settle()
        let new = harness.controller.key()
        #expect(new != old)
        // The system may give the restarted listener a different port.
        let restarted = try #require(harness.controller.endpointURL.flatMap(URL.init(string:)))
        #expect(try await post(restarted, key: old, ping).status == 401)
        #expect(try await post(restarted, key: new, ping).status == 200)
        _ = url
        harness.controller.shutDown()
    }

    @Test("A port already taken switches it off and says so")
    func portTaken() async throws {
        let first = try await Harness()
        let url = try await first.start()
        let port = try #require(url.port.flatMap(UInt16.init(exactly:)))

        let second = try await Harness(port: port)
        second.controller.setEnabled(true)
        await second.controller.settle()
        #expect(second.controller.status == .off)
        #expect(!second.controller.isEnabled)
        #expect(second.settings.bool(forKey: .agentAccessEnabled) == false)
        #expect(second.controller.lastError?.contains(String(port)) == true)
        first.controller.shutDown()
    }

    // MARK: Changes reach the window

    @Test("An agent's playlist appears in the window, with a notice, and the window stays put")
    func changeReachesModel() async throws {
        let harness = try await Harness()
        let url = try await harness.start()
        harness.model.show(.album(harness.track.albumKey))

        _ = try await callTool(url, key: harness.controller.key(), "create_playlist",
                               #"{"name":"From an agent","trackIDs":["\#(harness.track.id.uuidString)"]}"#)
        #expect(harness.model.playlists.map(\.name) == ["From an agent"])
        #expect(harness.model.notice == "An agent created the playlist “From an agent”")
        #expect(harness.model.screen == .album(harness.track.albumKey))
        #expect(harness.controller.lastChange?.summary == "Created the playlist “From an agent”")
        harness.controller.shutDown()
    }

    @Test("Likes, memories and catalogs an agent makes are re-read")
    func otherParts() async throws {
        let harness = try await Harness()
        let url = try await harness.start()
        let key = harness.controller.key()
        _ = try await callTool(url, key: key, "set_liked",
                               #"{"trackIDs":["\#(harness.track.id.uuidString)"],"liked":true}"#)
        #expect(harness.model.likedTrackIDs == [harness.track.id])

        _ = try await callTool(url, key: key, "save_memory",
                               #"{"trackID":"\#(harness.track.id.uuidString)","text":"On the train."}"#)
        #expect(harness.model.memories.map(\.text) == ["On the train."])

        _ = try await callTool(url, key: key, "save_catalog",
                               #"{"name":"Noughties","definition":{"rules":[{"field":"decade","op":"is","number":2000}]}}"#)
        let catalog = try #require(harness.model.catalogs.first)
        #expect(catalog.name == "Noughties")
        #expect(harness.model.albums(inCatalog: catalog.id).count == 1)
        harness.controller.shutDown()
    }

    @Test("Deleting the playlist on screen leaves its screen, as deleting it here does")
    func deleteOnScreen() async throws {
        let harness = try await Harness()
        let url = try await harness.start()
        let key = harness.controller.key()
        let created = try await callTool(url, key: key, "create_playlist", #"{"name":"Gone soon"}"#)
        let id = try #require((created["structuredContent"] as? [String: Any])?["id"] as? String)
        harness.model.show(.playlist(try #require(UUID(uuidString: id))))

        _ = try await callTool(url, key: key, "delete_playlist", #"{"playlistID":"\#(id)"}"#)
        #expect(harness.model.playlists.isEmpty)
        #expect(harness.model.screen == .library)
        #expect(harness.model.tab == .playlists)
        harness.controller.shutDown()
    }

    @Test("Settings builds the Claude Code command and describes the last change")
    func settingsText() {
        #expect(AgentAccessSettings.command(url: "http://127.0.0.1:47474/mcp", key: "k")
                == #"claude mcp add --transport http cadence http://127.0.0.1:47474/mcp --header "Authorization: Bearer k""#)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = AgentAccessController.Change(summary: "Created the playlist “Drive”", date: now)
        #expect(AgentAccessSettings.describe(fresh, now: now)
                == "Last change: an agent created the playlist “Drive”, just now.")
        let older = AgentAccessController.Change(summary: "Liked 2 tracks", date: now - 600)
        #expect(AgentAccessSettings.describe(older, now: now).hasPrefix("Last change: an agent liked 2 tracks, "))
    }

    @Test("Notices put the agent first")
    func notices() {
        #expect(AgentAccessController.notice(for: "Liked 2 tracks") == "An agent liked 2 tracks")
        #expect(AgentAccessController.notice(for: "") == "An agent changed the library")
    }
}
