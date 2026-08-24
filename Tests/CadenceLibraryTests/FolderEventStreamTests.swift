import Testing
import Foundation
@testable import CadenceLibrary

/// FSEvents delivery timing is not guaranteed, so these poll with a generous
/// timeout rather than a fixed sleep.
@Suite("Folder event stream")
struct FolderEventStreamTests {

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("Writing a file under a watched folder fires the callback")
    @MainActor
    func firesOnChange() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var received: FolderEventStream.EventID?
        let stream = FolderEventStream(url: folder, since: nil) { id in received = id }
        // Give the stream a moment to arm before the write, or the write can
        // race stream creation and be missed entirely.
        try await Task.sleep(for: .milliseconds(200))
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.flac"))

        await waitUntil { received != nil }
        #expect(received != nil)
        stream.stop()
    }

    @Test("A stream restarted with an old event ID replays what it missed")
    @MainActor
    func replaysSinceEventID() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var firstID: FolderEventStream.EventID?
        let first = FolderEventStream(url: folder, since: nil) { id in firstID = id }
        try await Task.sleep(for: .milliseconds(200))
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.flac"))
        await waitUntil { firstID != nil }
        let capturedID = try #require(firstID)
        first.stop()

        // Written while nothing was watching — the case a relaunch has to
        // catch up on rather than forcing a full rescan.
        try Data("y".utf8).write(to: folder.appendingPathComponent("b.flac"))

        var replayed = false
        let second = FolderEventStream(url: folder, since: capturedID) { _ in replayed = true }
        await waitUntil { replayed }
        #expect(replayed)
        second.stop()
    }
}
