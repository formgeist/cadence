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

// MARK: - Kept songs

/// Every file in a folder, hidden ones included, or none when it is missing.
private func everything(in directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
}

@Suite("Kept songs", .serialized)
struct RemoteDownloadsTests {

    private func location(_ n: Int) -> URL {
        RemoteTrackLocation.url(songID: "tr-song-\(n)", suffix: "flac")
    }

    /// A cache folder and a kept folder side by side, removed afterwards.
    private func folders(_ name: String) -> (cache: URL, kept: RemoteDownloads, root: URL) {
        let root = scratch(name)
        return (root.appendingPathComponent("cache"),
                RemoteDownloads(directory: root.appendingPathComponent("downloads")), root)
    }

    @Test("Keeping downloads once, and playback then uses the kept file")
    func keepOnce() async throws {
        let (cache, kept, root) = folders("keep-once")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader()
        let source = RemoteTrackSource(downloader: downloader, directory: cache, downloads: kept)

        let file = try await source.keep(location(1))
        #expect(file.deletingLastPathComponent().standardizedFileURL
                == kept.directory.standardizedFileURL)
        #expect(kept.file(for: location(1)) == file)
        #expect(try await source.fileURL(for: location(1)) == file)
        #expect(try await source.keep(location(1)) == file)
        #expect(await downloader.started() == 1)
    }

    @Test("A cached song nothing is playing is moved into the kept folder")
    func keepMovesCached() async throws {
        let (cache, kept, root) = folders("keep-moves")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader()
        let player = RemoteTrackSource(downloader: downloader, directory: cache)
        let cached = try await player.fileURL(for: location(1))

        // A second source over the same cache has handed nothing out.
        let source = RemoteTrackSource(downloader: downloader, directory: cache, downloads: kept)
        let file = try await source.keep(location(1))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        #expect(await downloader.started() == 1)
    }

    @Test("A song just handed out for playback is copied, not moved")
    func keepCopiesPlaying() async throws {
        let (cache, kept, root) = folders("keep-copies")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader()
        let source = RemoteTrackSource(downloader: downloader, directory: cache, downloads: kept)
        let playing = try await source.fileURL(for: location(1))

        let file = try await source.keep(location(1))
        #expect(file != playing)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: playing.path))
        #expect(await downloader.started() == 1)
    }

    @Test("Playing and keeping at once share one download")
    func keepSharesWithPlayback() async throws {
        let (cache, kept, root) = folders("keep-shares")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader(held: true)
        let source = RemoteTrackSource(downloader: downloader, directory: cache, downloads: kept)

        async let playing = source.fileURL(for: location(1))
        async let keeping = source.keep(location(1))
        try await Task.sleep(for: .milliseconds(100))
        await downloader.release()
        let (played, file) = try await (playing, keeping)
        #expect(FileManager.default.fileExists(atPath: played.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(kept.songIDs() == ["tr-song-1"])
        #expect(await downloader.started() == 1)
    }

    @Test("Cancelling a keep leaves nothing in the kept folder")
    func keepCancelled() async throws {
        let (cache, kept, root) = folders("keep-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader(held: true)
        let source = RemoteTrackSource(downloader: downloader, directory: cache, downloads: kept)

        let task = Task { try await source.keep(location(1)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await downloader.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(everything(in: kept.directory).isEmpty)
        #expect(everything(in: cache).isEmpty)
        #expect(kept.file(for: location(1)) == nil)
    }

    @Test("Kept songs are outside the cache's budget")
    func keptSurviveBudget() async throws {
        let (cache, kept, root) = folders("keep-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = RemoteTrackSource(downloader: FakeDownloader(size: 1000), directory: cache,
                                       budget: 1500, protectedCount: 1, downloads: kept)
        let file = try await source.keep(location(1))
        for n in 2...5 {
            _ = try await source.fileURL(for: location(n))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await source.fileURL(for: location(1)) == file)
        // The cache trimmed meanwhile, down to the files it protects: the
        // last one handed out and the one just downloaded.
        #expect(everything(in: cache).count <= 2)
    }

    @Test("A keep waiting on a download survives other songs filling the cache")
    func keepGuardedFromTrim() async throws {
        let (cache, kept, root) = folders("keep-guard")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader(size: 1000, held: true)
        let source = RemoteTrackSource(downloader: downloader, directory: cache,
                                       budget: 1500, protectedCount: 1, downloads: kept)

        let keeping = Task { try await source.keep(location(1)) }
        let others = (2...4).map { n in Task { try await source.fileURL(for: location(n)) } }
        try await Task.sleep(for: .milliseconds(100))
        await downloader.release()
        for other in others { _ = try await other.value }
        let file = try await keeping.value
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(kept.songIDs() == ["tr-song-1"])
    }

    @Test("Listing, sizing and removing kept songs")
    func folder() async throws {
        let (cache, kept, root) = folders("keep-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(kept.songIDs().isEmpty)
        #expect(kept.totalBytes() == 0)

        let source = RemoteTrackSource(downloader: FakeDownloader(size: 1000), directory: cache,
                                       downloads: kept)
        _ = try await source.keep(location(1))
        _ = try await source.keep(location(2))
        _ = try await source.keep(RemoteTrackLocation.url(songID: "tr-song-3", suffix: "mp3"))
        #expect(kept.songIDs() == ["tr-song-1", "tr-song-2", "tr-song-3"])
        #expect(kept.totalBytes() == 3000)

        let excluded = try kept.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(excluded.isExcludedFromBackup == true)

        // Removed whatever its suffix.
        kept.remove(songID: "tr-song-3")
        kept.remove(songID: "tr-song-9")
        #expect(kept.songIDs() == ["tr-song-1", "tr-song-2"])

        kept.removeAll()
        #expect(kept.songIDs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: kept.directory.path))
    }

    @Test("Clearing the cache leaves kept songs alone")
    func clearingCache() async throws {
        let (cache, kept, root) = folders("keep-clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = RemoteTrackSource(downloader: FakeDownloader(), directory: cache, downloads: kept)
        _ = try await source.fileURL(for: location(1))
        let file = try await source.keep(location(2))

        await source.removeAll()
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A location that is not a remote track's is not found")
    func invalidLocation() async throws {
        let (cache, kept, root) = folders("keep-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = RemoteTrackSource(downloader: FakeDownloader(), directory: cache, downloads: kept)
        await #expect(throws: RemoteError.notFound) {
            _ = try await source.keep(URL(fileURLWithPath: "/tmp/x.flac"))
        }
        #expect(kept.file(for: URL(fileURLWithPath: "/tmp/x.flac")) == nil)
        #expect(everything(in: kept.directory).isEmpty)
    }
}

// MARK: - Download queue

/// Keeps songs on command: each keep waits until it is finished, failed or
/// cancelled, so a test decides the order things happen in. An answer given
/// before its keep arrives is held for it.
private actor FakeKeeper {
    private(set) var started: [String] = []
    private(set) var peak = 0
    private var gates: [String: CheckedContinuation<Result<URL, any Error>, Never>] = [:]
    private var early: [String: Result<URL, any Error>] = [:]

    var active: Int { gates.count }

    func keep(_ location: URL) async throws -> URL {
        let id = RemoteTrackLocation.parse(location)!.songID
        started.append(id)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { open(id, $0) }
        } onCancel: {
            Task { await self.end(id, .failure(CancellationError()), holding: false) }
        }
        return try result.get()
    }

    func finish(_ id: String) { end(id, .success(URL(fileURLWithPath: "/kept/\(id)")), holding: true) }
    func fail(_ id: String, _ error: RemoteError) { end(id, .failure(error), holding: true) }

    private func open(_ id: String, _ gate: CheckedContinuation<Result<URL, any Error>, Never>) {
        if let result = early.removeValue(forKey: id) {
            gate.resume(returning: result)
            return
        }
        // Cancelled before it got here: the handler has already run.
        if Task.isCancelled {
            gate.resume(returning: .failure(CancellationError()))
            return
        }
        gates[id] = gate
        peak = max(peak, gates.count)
    }

    private func end(_ id: String, _ result: Result<URL, any Error>, holding: Bool) {
        if let gate = gates.removeValue(forKey: id) {
            gate.resume(returning: result)
        } else if holding {
            early[id] = result
        }
    }
}

@Suite("Download queue", .serialized)
struct RemoteDownloadQueueTests {

    private func songs(_ numbers: ClosedRange<Int>) -> [URL] {
        numbers.map { RemoteTrackLocation.url(songID: "tr-song-\($0)", suffix: "flac") }
    }

    private func id(_ n: Int) -> String { "tr-song-\(n)" }

    /// Waits until the queue's state passes `condition`, or fails after a second.
    private func until(_ queue: RemoteDownloadQueue,
                       _ condition: @escaping (RemoteDownloadQueue.Snapshot) -> Bool) async throws {
        for _ in 0..<200 {
            if condition(await queue.snapshot) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The queue never reached the expected state: \(await queue.snapshot)")
    }

    /// Lets the queue's tasks reach the keeper.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

    private func makeQueue(_ keeper: FakeKeeper, paused: Bool = false) -> RemoteDownloadQueue {
        RemoteDownloadQueue(concurrency: 2, paused: paused) { try await keeper.keep($0) }
    }

    @Test("Songs are kept in order, two at a time")
    func order() async throws {
        let keeper = FakeKeeper()
        let queue = makeQueue(keeper)
        await queue.enqueue(group: "album:1", locations: songs(1...4))
        try await settle()
        #expect(await keeper.started == [id(1), id(2)])

        await keeper.finish(id(1))
        try await until(queue) { $0.songs[id(1)] == .kept && $0.songs[id(3)] == .downloading }
        await keeper.finish(id(2))
        await keeper.finish(id(3))
        try await settle()
        await keeper.finish(id(4))
        try await until(queue) { $0.isFinished("album:1") }

        #expect(await keeper.started == [id(1), id(2), id(3), id(4)])
        #expect(await keeper.peak == 2)
        let progress = await queue.snapshot.progress(of: "album:1")
        #expect(progress.kept == 4 && progress.total == 4)
    }

    @Test("A song in two groups is kept once and wanted until both are cancelled")
    func sharedSong() async throws {
        let keeper = FakeKeeper()
        let queue = makeQueue(keeper)
        await queue.enqueue(group: "album:1", locations: songs(1...2))
        await queue.enqueue(group: "playlist:1", locations: songs(2...2))
        try await settle()

        await queue.cancel(group: "album:1")
        try await settle()
        // Song 1 was only the album's: stopped and dropped. Song 2 carries on.
        let snapshot = await queue.snapshot
        #expect(snapshot.songs[id(1)] == nil)
        #expect(snapshot.songs[id(2)] == .downloading)
        #expect(snapshot.groups["playlist:1"] == [id(2)])

        await keeper.finish(id(2))
        try await until(queue) { $0.songs[id(2)] == .kept }
        #expect(await keeper.started.filter { $0 == id(2) }.count == 1)
    }

    @Test("Cancelling a group stops its running songs and drops its queued ones")
    func cancelGroup() async throws {
        let keeper = FakeKeeper()
        let queue = makeQueue(keeper)
        await queue.enqueue(group: "album:1", locations: songs(1...3))
        await queue.enqueue(group: "album:2", locations: songs(4...4))
        try await settle()
        await queue.cancel(group: "album:1")
        try await settle()

        // The other album takes the free places.
        #expect(await keeper.started == [id(1), id(2), id(4)])
        #expect(await keeper.active == 1)
        let snapshot = await queue.snapshot
        #expect(snapshot.groups.keys.sorted() == ["album:2"])
        #expect(snapshot.songs.keys.sorted() == [id(4)])
    }

    @Test("A failed song stays failed while the rest go on, until retried")
    func failure() async throws {
        let keeper = FakeKeeper()
        let queue = makeQueue(keeper)
        await queue.enqueue(group: "album:1", locations: songs(1...3))
        try await settle()
        await keeper.fail(id(1), .notFound)
        try await until(queue) { $0.songs[id(3)] == .downloading }
        #expect(await queue.snapshot.songs[id(1)] == .failed(message: RemoteError.notFound.message))

        await keeper.finish(id(2))
        await keeper.finish(id(3))
        try await until(queue) { $0.isFinished("album:1") }
        #expect(await queue.snapshot.progress(of: "album:1").kept == 2)

        await queue.retryFailed(in: "album:1")
        try await until(queue) { $0.songs[id(1)] == .downloading }
        await keeper.finish(id(1))
        try await until(queue) { $0.progress(of: "album:1").kept == 3 }
    }

    @Test("Pausing puts running songs back in front, and resuming starts them again")
    func pauseAndResume() async throws {
        let keeper = FakeKeeper()
        let queue = makeQueue(keeper)
        await queue.enqueue(group: "album:1", locations: songs(1...3))
        try await settle()
        await queue.pause()
        try await settle()
        #expect(await keeper.active == 0)
        let paused = await queue.snapshot
        #expect(paused.paused)
        #expect(paused.songs.values.allSatisfy { $0 == .queued })

        await queue.resume()
        try await settle()
        #expect(await keeper.started == [id(1), id(2), id(1), id(2)])
    }

    @Test("Losing the Mac pauses the queue instead of failing every song")
    func connectionLost() async throws {
        let keeper = FakeKeeper()
        let queue = makeQueue(keeper)
        await queue.enqueue(group: "album:1", locations: songs(1...3))
        try await settle()
        await keeper.fail(id(1), .unreachable)
        try await until(queue) { $0.paused }
        try await settle()

        let snapshot = await queue.snapshot
        #expect(snapshot.songs.values.allSatisfy { $0 == .queued })
        #expect(await keeper.active == 0)
        #expect(await keeper.started == [id(1), id(2)])

        await queue.resume()
        try await settle()
        #expect(await keeper.started.count == 4)
    }

    @Test("A queue created paused starts nothing until resumed")
    func startsPaused() async throws {
        let keeper = FakeKeeper()
        let queue = makeQueue(keeper, paused: true)
        await queue.enqueue(group: "album:1", locations: songs(1...2))
        try await settle()
        #expect(await keeper.started.isEmpty)
        await queue.resume()
        try await settle()
        #expect(await keeper.started == [id(1), id(2)])
    }

    @Test("Cancelling everything empties the queue")
    func cancelAll() async throws {
        let keeper = FakeKeeper()
        let queue = makeQueue(keeper)
        await queue.enqueue(group: "album:1", locations: songs(1...3))
        await queue.enqueue(group: "playlist:1", locations: songs(4...5))
        try await settle()
        await queue.cancelAll()
        try await settle()
        #expect(await keeper.active == 0)
        #expect(await queue.snapshot == RemoteDownloadQueue.Snapshot())
    }

    @Test("Snapshots arrive as the queue changes")
    func snapshots() async throws {
        let keeper = FakeKeeper()
        let queue = makeQueue(keeper)
        let stream = await queue.snapshots()
        var states = stream.makeAsyncIterator()
        #expect(await states.next() == RemoteDownloadQueue.Snapshot())
        await queue.enqueue(group: "album:1", locations: songs(1...1))
        let queued = await states.next()
        #expect(queued?.songs[id(1)] == .downloading)
        await keeper.finish(id(1))
        let kept = await states.next()
        #expect(kept?.songs[id(1)] == .kept)
    }

    @Test("Anything that is not a remote track is ignored")
    func ignoresOtherLocations() async throws {
        let queue = makeQueue(FakeKeeper(), paused: true)
        await queue.enqueue(group: "album:1", locations: [URL(fileURLWithPath: "/tmp/x.flac")])
        #expect(await queue.snapshot.groups["album:1"] == [])
        #expect(await queue.snapshot.songs.isEmpty)
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
