import Testing
import Foundation
import CadenceCore
import CadenceLibrary
@testable import CadenceServer
@testable import CadenceRemote

private func scratch(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cadence-remote-\(name)-\(UUID().uuidString)")
}

// MARK: - Mapping

@Suite("Remote models as the app's models", .serialized)
struct RemoteMappingTests {

    @Test("An album maps onto the same ids the Mac uses")
    func album() async throws {
        try await withServer { server in
            let client = try await server.pair()
            let remote = try #require(try await client.albums(.newest).first)
            let album = Album(remote: try await client.album(id: remote.id))

            // The key is rebuilt from the same name, title and year, so its
            // stable id is the one the server sent.
            #expect(album.stableID == remote.id)
            #expect(album.albumArtist == "Vera Lindqvist")
            #expect(album.tracks.map(\.title) == ["Morning Static", "Slow Hours"])

            // Track ids are the Mac's own.
            let macIDs = Set(try await server.store.tracks(offset: 0, limit: 10).map(\.id))
            #expect(Set(album.tracks.map(\.id)) == macIDs)

            let track = try #require(album.tracks.first)
            #expect(track.format.codec == .flac)
            #expect(track.format.sampleRate == 44_100)
            #expect(track.format.bitDepth == 16)
            #expect(track.duration == 201)
            #expect(track.dateAdded == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(track.albumKey == album.key)

            let location = try #require(RemoteTrackLocation.parse(track.url))
            #expect(location.songID == "tr-" + track.id.uuidString.lowercased())
            #expect(location.suffix == "flac")
        }
    }

    @Test("A playlist keeps its id, order and repeats")
    func playlist() throws {
        let first = UUID(), second = UUID(), list = UUID()
        let json = """
        {"id":"pl-\(list.uuidString.lowercased())","name":"Evening","songCount":3,"duration":600,
         "changed":"2026-01-02T03:04:05Z","coverArt":"ab",
         "entry":[{"id":"tr-\(first.uuidString.lowercased())","title":"A"},
                  {"id":"tr-\(second.uuidString.lowercased())","title":"B"},
                  {"id":"tr-\(first.uuidString.lowercased())","title":"A"}]}
        """
        let remote = try JSONDecoder().decode(RemotePlaylist.self, from: Data(json.utf8))
        let playlist = try #require(Playlist(remote: remote))
        #expect(playlist.id == list)
        #expect(playlist.trackIDs == [first, second, first])
        #expect(playlist.duration == 600)
        #expect(playlist.artworkID == "ab")
        #expect(playlist.updatedAt == Date(timeIntervalSince1970: 1_767_323_045))
    }

    @Test("Ids that are not the server's are refused")
    func foreignIDs() throws {
        let song = try JSONDecoder().decode(RemoteSong.self, from: Data(#"{"id":"42","title":"x"}"#.utf8))
        #expect(Track(remote: song) == nil)
        let playlist = try JSONDecoder().decode(
            RemotePlaylist.self,
            from: Data(#"{"id":"tr-00000000-0000-0000-0000-000000000000","name":"x","songCount":0,"duration":0}"#.utf8))
        #expect(Playlist(remote: playlist) == nil)
    }

    @Test("An m4a with a bit depth is ALAC, without one AAC")
    func m4a() throws {
        func format(_ json: String) throws -> AudioFormat {
            AudioFormat(remote: try JSONDecoder().decode(RemoteSong.self, from: Data(json.utf8)))
        }
        #expect(try format(#"{"id":"s","title":"t","suffix":"m4a","bitDepth":24,"samplingRate":96000}"#).codec == .alac)
        #expect(try format(#"{"id":"s","title":"t","suffix":"m4a","bitRate":256}"#).codec == .aac)
        #expect(try format(#"{"id":"s","title":"t","suffix":"mp3","bitRate":320}"#).bitRate == 320)
    }

    @Test("Only a remote track's location parses, and only with safe parts", arguments: [
        "file:///Users/x/song.flac",
        "cadence-remote://album/tr-1",
        "cadence-remote://song/",
        "cadence-remote://song/..%2Fetc",
        "cadence-remote://song/tr-1/../../x",
        "cadence-remote://song/tr-1?suffix=fl/ac",
        "https://song/tr-1",
    ])
    func location(text: String) throws {
        #expect(RemoteTrackLocation.parse(try #require(URL(string: text))) == nil)
    }

    @Test("A location survives the round trip")
    func locationRoundTrip() {
        let url = RemoteTrackLocation.url(songID: "tr-abc-123", suffix: "FLAC")
        #expect(url.absoluteString == "cadence-remote://song/tr-abc-123?suffix=FLAC")
        let parsed = RemoteTrackLocation.parse(url)
        #expect(parsed?.songID == "tr-abc-123")
        #expect(parsed?.suffix == "flac")
    }
}

// MARK: - Track source

/// Writes a file of `size` bytes per song, counting each download. Holds
/// every download until `release()` when `held` is set.
private actor FakeDownloader: RemoteSongDownloading {
    var count = 0
    var cancelled = 0
    private let size: Int
    private var held: Bool
    private var gate: [CheckedContinuation<Void, Never>] = []

    init(size: Int = 1000, held: Bool = false) {
        self.size = size
        self.held = held
    }

    func release() {
        held = false
        gate.forEach { $0.resume() }
        gate = []
    }

    func started() -> Int { count }

    nonisolated func download(songID: String, to destination: URL) async throws {
        await begin()
        do {
            try await Task.sleep(for: .milliseconds(10))
            if await isHeld() { await wait() }
            try Task.checkCancellation()
        } catch {
            await noteCancelled()
            throw CancellationError()
        }
        try Data(repeating: 7, count: size).write(to: destination)
    }

    private func begin() { count += 1 }
    private func isHeld() -> Bool { held }
    private func noteCancelled() { cancelled += 1 }
    private func wait() async {
        await withCheckedContinuation { gate.append($0) }
    }
}

/// Answers "busy" `refusals` times, then writes the file.
private actor BusyDownloader: RemoteSongDownloading {
    var attempts = 0
    private var refusals: Int
    private let wait: TimeInterval

    init(refusals: Int, wait: TimeInterval) {
        self.refusals = refusals
        self.wait = wait
    }

    func download(songID: String, to destination: URL) async throws {
        attempts += 1
        if refusals > 0 {
            refusals -= 1
            throw RemoteError.busy(retryAfter: wait)
        }
        try Data(repeating: 7, count: 100).write(to: destination)
    }
}

@Suite("Remote track source", .serialized)
struct RemoteTrackSourceTests {

    private func location(_ n: Int) -> URL {
        RemoteTrackLocation.url(songID: "tr-song-\(n)", suffix: "flac")
    }

    @Test("A song's file is downloaded once and found again")
    func live() async throws {
        try await withServer { server in
            let client = try await server.pair()
            let song = try #require(try await client.search("morning").song.first)
            let track = try #require(Track(remote: song))
            let directory = scratch("tracks")
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = RemoteTrackSource(downloader: client, directory: directory)

            let file = try await source.fileURL(for: track.url)
            let arrived = try Data(contentsOf: file) == server.audio
            #expect(arrived)
            #expect(file.deletingLastPathComponent().standardizedFileURL
                    == directory.standardizedFileURL)

            // With the server gone, the cached file still plays.
            server.listener.stop()
            #expect(try await source.fileURL(for: track.url) == file)
        }
    }

    @Test("Two callers asking at once share one download")
    func shared() async throws {
        let directory = scratch("shared")
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = FakeDownloader(held: true)
        let source = RemoteTrackSource(downloader: downloader, directory: directory)
        let url = location(1)

        async let first = source.fileURL(for: url)
        async let second = source.fileURL(for: url)
        try await Task.sleep(for: .milliseconds(100))
        await downloader.release()
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(await downloader.started() == 1)
        _ = try await source.fileURL(for: url)
        #expect(await downloader.started() == 1)
    }

    @Test("A skip cancels the download and leaves nothing behind")
    func cancelled() async throws {
        let directory = scratch("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = FakeDownloader(held: true)
        let source = RemoteTrackSource(downloader: downloader, directory: directory)

        let task = Task { try await source.fileURL(for: location(1)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await downloader.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await downloader.cancelled == 1)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(left.isEmpty)

        // Asking again starts a new download, which completes.
        _ = try await source.fileURL(for: location(1))
        #expect(await downloader.started() == 2)
    }

    @Test("One caller giving up does not stop the download another waits for")
    func oneOfTwoCancelled() async throws {
        let directory = scratch("one-of-two")
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = FakeDownloader(held: true)
        let source = RemoteTrackSource(downloader: downloader, directory: directory)

        let leaving = Task { try await source.fileURL(for: location(1)) }
        let staying = Task { try await source.fileURL(for: location(1)) }
        try await Task.sleep(for: .milliseconds(100))
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        await downloader.release()
        let file = try await staying.value
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await downloader.cancelled == 0)
    }

    @Test("Past its budget the cache removes the file used longest ago")
    func budget() async throws {
        let directory = scratch("budget")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RemoteTrackSource(downloader: FakeDownloader(size: 1000),
                                       directory: directory, budget: 2500, protectedCount: 1)
        let one = try await source.fileURL(for: location(1))
        try await Task.sleep(for: .milliseconds(20))
        let two = try await source.fileURL(for: location(2))
        try await Task.sleep(for: .milliseconds(20))
        // Using the first again makes the second the oldest.
        _ = try await source.fileURL(for: location(1))
        try await Task.sleep(for: .milliseconds(20))
        let three = try await source.fileURL(for: location(3))

        #expect(FileManager.default.fileExists(atPath: one.path))
        #expect(!FileManager.default.fileExists(atPath: two.path))
        #expect(FileManager.default.fileExists(atPath: three.path))
    }

    @Test("A briefly busy Mac is waited for; a long refusal fails the track")
    func busy() async throws {
        let directory = scratch("busy")
        defer { try? FileManager.default.removeItem(at: directory) }

        let brief = BusyDownloader(refusals: 2, wait: 0.01)
        let source = RemoteTrackSource(downloader: brief, directory: directory)
        let file = try await source.fileURL(for: location(1))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await brief.attempts == 3)

        let long = BusyDownloader(refusals: 1, wait: 600)
        let refused = RemoteTrackSource(downloader: long, directory: directory)
        await #expect(throws: PlaybackError.engine(RemoteError.busy(retryAfter: 600).message)) {
            _ = try await refused.fileURL(for: location(2))
        }
        #expect(await long.attempts == 1)

        let endless = BusyDownloader(refusals: 100, wait: 0.01)
        let givesUp = RemoteTrackSource(downloader: endless, directory: directory, busyRetries: 2)
        await #expect(throws: PlaybackError.self) {
            _ = try await givesUp.fileURL(for: location(3))
        }
        #expect(await endless.attempts == 3)
    }

    @Test("A failure is a playback error the listener can read")
    func failure() async throws {
        try await withServer { server in
            let client = try await server.pair()
            let directory = scratch("failure")
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = RemoteTrackSource(downloader: client, directory: directory)
            let missing = RemoteTrackLocation.url(
                songID: "tr-" + UUID().uuidString.lowercased(), suffix: "flac")
            await #expect(throws: PlaybackError.engine(RemoteError.notFound.message)) {
                _ = try await source.fileURL(for: missing)
            }
            await #expect(throws: PlaybackError.self) {
                _ = try await source.fileURL(for: URL(fileURLWithPath: "/tmp/x.flac"))
            }
            let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            #expect(left.isEmpty)
        }
    }
}

// MARK: - Metadata cache

@Suite("Remote metadata cache", .serialized)
struct RemoteMetadataCacheTests {

    @Test("Browsed answers are there when the Mac is not")
    func offline() async throws {
        let directory = scratch("metadata")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RemoteMetadataCache(directory: directory)
        try await withServer { server in
            let client = try await server.pair(cache: cache)
            await expectError(.notCached) { _ = try await client.artists(source: .cache) }

            let artists = try await client.artists()
            let albums = try await client.albums(.newest)
            let album = try await client.album(id: try #require(albums.first?.id))
            let playlists = try await client.playlists()
            _ = try await client.search("slow")

            server.listener.stop()
            await expectError(.unreachable) { _ = try await client.artists() }

            #expect(try await client.artists(source: .cache) == artists)
            #expect(try await client.albums(.newest, source: .cache) == albums)
            #expect(try await client.album(id: album.id, source: .cache) == album)
            #expect(try await client.playlists(source: .cache) == playlists)
            // Different parameters are a different answer.
            await expectError(.notCached) {
                _ = try await client.albums(.newest, size: 5, source: .cache)
            }
            await expectError(.notCached) { _ = try await client.starred(source: .cache) }

            // The key is nowhere in the cache.
            let key = client.credentials.apiKey
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                #expect(!name.contains(key))
                let text = String(decoding: try Data(contentsOf: directory.appendingPathComponent(name)),
                                  as: UTF8.self)
                #expect(!text.contains(key))
            }

            cache.removeAll()
            await expectError(.notCached) { _ = try await client.artists(source: .cache) }
        }
    }
}

// MARK: - Connection

/// A scripted server: each `connect` takes the next outcome.
private actor Script {
    private var outcomes: [Result<RemoteLibraryClient.ServerInfo, RemoteError>]
    private(set) var calls = 0

    init(_ outcomes: [Result<RemoteLibraryClient.ServerInfo, RemoteError>]) {
        self.outcomes = outcomes
    }

    func next() throws -> RemoteLibraryClient.ServerInfo {
        calls += 1
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        return try outcome.get()
    }
}

private let info = RemoteLibraryClient.ServerInfo(serverVersion: "1.0", protocolVersion: 1)

/// Waits for the first state that matches, or fails after two seconds.
private func reach(
    _ connection: RemoteConnection, sourceLocation: SourceLocation = #_sourceLocation,
    _ matches: @escaping @Sendable (RemoteConnection.State) -> Bool
) async -> [RemoteConnection.State] {
    let states = await connection.states()
    let seen = await withTaskGroup(of: [RemoteConnection.State]?.self) { group in
        group.addTask {
            var seen: [RemoteConnection.State] = []
            for await state in states {
                seen.append(state)
                if matches(state) { return seen }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    guard let seen else {
        Issue.record("State never reached; now \(await connection.state)",
                     sourceLocation: sourceLocation)
        return []
    }
    return seen
}

@Suite("Remote connection")
struct RemoteConnectionTests {

    @Test("An unanswered Mac is retried with growing waits until it answers")
    func backoff() async {
        let script = Script([.failure(.unreachable), .failure(.unreachable), .success(info)])
        let (network, _) = AsyncStream<Bool>.makeStream()
        let delays = Delays()
        let connection = RemoteConnection(connect: { try await script.next() }, network: network,
                                          sleep: { await delays.record($0) })
        let observed = await connection.states()
        await connection.start()
        _ = await reach(connection) { $0 == .connected(info) }
        await connection.stop()
        var states: [RemoteConnection.State] = []
        for await state in observed {
            states.append(state)
            if state == .connected(info) { break }
        }
        #expect(states.contains(.unreachable(retryIn: 2)))
        #expect(states.contains(.unreachable(retryIn: 4)))
        #expect(await delays.values == [2, 4])
    }

    @Test("Something only the user can fix waits for the user")
    func needsAttention() async throws {
        let script = Script([.failure(.notPaired), .success(info)])
        let (network, networkInput) = AsyncStream<Bool>.makeStream()
        let connection = RemoteConnection(connect: { try await script.next() }, network: network,
                                          sleep: { _ in })
        await connection.start()
        _ = await reach(connection) { $0 == .needsAttention(.notPaired) }
        // Neither time nor a network change brings another try.
        networkInput.yield(false)
        networkInput.yield(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await script.calls == 1)

        await connection.retryNow()
        _ = await reach(connection) { $0 == .connected(info) }
        #expect(await script.calls == 2)
        await connection.stop()
    }

    @Test("Offline waits for the network, then connects at once")
    func offline() async throws {
        let script = Script([.success(info)])
        let (network, networkInput) = AsyncStream<Bool>.makeStream()
        let connection = RemoteConnection(connect: { try await script.next() }, network: network,
                                          sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        await connection.start()
        _ = await reach(connection) { $0 == .connected(info) }

        networkInput.yield(false)
        _ = await reach(connection) { $0 == .offline }
        networkInput.yield(true)
        _ = await reach(connection) { $0 == .connected(info) }
        #expect(await script.calls == 2)
        await connection.stop()
    }

    @Test("A lost connection reported by a request reconnects; other errors do not")
    func lost() async throws {
        let script = Script([.success(info)])
        let (network, _) = AsyncStream<Bool>.makeStream()
        let connection = RemoteConnection(connect: { try await script.next() }, network: network,
                                          sleep: { _ in })
        await connection.start()
        _ = await reach(connection) { $0 == .connected(info) }

        await connection.connectionLost(.notFound)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await script.calls == 1)

        await connection.connectionLost(.unreachable)
        try await Task.sleep(for: .milliseconds(50))
        _ = await reach(connection) { $0 == .connected(info) }
        #expect(await script.calls == 2)
        await connection.stop()
        #expect(await connection.state == .idle)
    }
}

private actor Delays {
    var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}
