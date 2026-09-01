import Testing
import Foundation
@testable import CadenceCore

/// Records what the controller asked the engine to do, so the gapless handshake
/// and gain resolution can be asserted on without any audio.
@MainActor
final class SpyEngine: PlayerEngine {
    let events: AsyncStream<EngineEvent>
    let positions: AsyncStream<TimeInterval>
    private let eventSink: AsyncStream<EngineEvent>.Continuation
    private let positionSink: AsyncStream<TimeInterval>.Continuation

    var volume: Double = 1
    var currentTime: TimeInterval = 0

    private(set) var played: [URL] = []
    private(set) var prepared: [URL] = []
    private(set) var gains: [Double] = []
    private(set) var clearNextCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var seeks: [TimeInterval] = []

    init() {
        (events, eventSink) = AsyncStream.makeStream()
        (positions, positionSink) = AsyncStream.makeStream()
    }

    /// Files the engine refuses to open, by last path component — a corrupt
    /// rip, or one the volume no longer has. Both `play` and `prepareNext`
    /// honour it, so the direct and the gapless path can be driven the same way.
    var unopenable: Set<String> = []

    func play(url: URL, duration: TimeInterval, gain: Double) throws {
        played.append(url)
        gains.append(gain)
        if unopenable.contains(url.lastPathComponent) {
            throw PlaybackError.unsupportedFormat("test")
        }
    }

    func prepareNext(url: URL, duration: TimeInterval, gain: Double) throws {
        prepared.append(url)
        if unopenable.contains(url.lastPathComponent) {
            throw PlaybackError.unsupportedFormat("test")
        }
    }

    func clearNext() { clearNextCount += 1 }
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func stop() {}
    func seek(to time: TimeInterval) { seeks.append(time) }

    /// Deliver an event and let the controller's stream loop drain it.
    func emit(_ event: EngineEvent) async {
        eventSink.yield(event)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private func makeTrack(_ title: String, seconds: TimeInterval = 100,
                       gain: Double? = nil) -> Track {
    Track(
        url: URL(fileURLWithPath: "/music/\(title).flac"),
        title: title, artist: "Artist", albumTitle: "Album",
        duration: seconds,
        replayGain: gain.map { ReplayGain(trackGain: $0, albumGain: $0 - 1) }
    )
}

@MainActor
@Suite("PlaybackController")
struct PlaybackControllerTests {

    @Test("Playing a track queues its whole context and starts at the right one")
    func playsInContext() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]

        controller.play(tracks[1], in: tracks)

        #expect(controller.queue.count == 3)
        #expect(controller.currentIndex == 1)
        #expect(controller.currentTrack?.title == "B")
        #expect(engine.played.last?.lastPathComponent == "B.flac")
    }

    @Test("A play remembers the playlist it came from, until the next fresh start")
    func remembersPlaylistOrigin() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]
        let listID = UUID()

        controller.play(tracks, fromPlaylist: listID)
        #expect(controller.startedFromPlaylist == listID)

        // Advancing within the queue keeps the credit — a gapless handoff to
        // the next playlist track is still the playlist playing.
        controller.next()
        #expect(controller.startedFromPlaylist == listID)

        // An album (or any non-playlist start) clears it.
        controller.play(tracks[0], in: tracks)
        #expect(controller.startedFromPlaylist == nil)
    }

    @Test("The next track is prepared the moment this one starts, not near its end")
    func preparesNextOnStart() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B")]

        controller.play(tracks[0], in: tracks)
        await engine.emit(.started(tracks[0].url))

        #expect(engine.prepared.map(\.lastPathComponent) == ["B.flac"])
    }

    @Test("The last track of a queue prepares nothing")
    func lastTrackPreparesNothing() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B")]

        controller.play(tracks[1], in: tracks)
        await engine.emit(.started(tracks[1].url))

        #expect(engine.prepared.isEmpty)
    }

    @Test("Repeat-all prepares the first track after the last")
    func repeatAllWrapsWhenPreparing() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B")]
        controller.repeatMode = .all

        controller.play(tracks[1], in: tracks)
        await engine.emit(.started(tracks[1].url))

        #expect(engine.prepared.map(\.lastPathComponent) == ["A.flac"])
    }

    @Test("The controller follows the engine's own transition instead of restarting it")
    func followsGaplessTransition() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B")]

        controller.play(tracks[0], in: tracks)
        await engine.emit(.started(tracks[0].url))
        let playCountBefore = engine.played.count

        await engine.emit(.advancedToNext(tracks[1].url))

        #expect(controller.currentTrack?.title == "B")
        #expect(controller.state.isPlaying)
        // The crucial assertion: no second play() call, which would re-decode
        // and produce the gap the handshake exists to avoid.
        #expect(engine.played.count == playCountBefore)
    }

    @Test("Reaching the end of a queue with no repeat stops")
    func finishesAtEndOfQueue() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A")]

        controller.play(tracks[0], in: tracks)
        await engine.emit(.started(tracks[0].url))
        await engine.emit(.finished)

        #expect(controller.state == .idle)
        #expect(controller.currentTrack == nil)
    }

    @Test("Previous restarts the track when past the first few seconds")
    func previousRestartsWhenLateIn() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B")]

        controller.play(tracks[1], in: tracks)
        controller.seek(to: 40)
        engine.clearSeeks()
        controller.previous()

        #expect(controller.currentTrack?.title == "B")
        #expect(engine.seeks == [0])
    }

    @Test("Previous steps back when only just started")
    func previousStepsBackWhenEarly() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B")]

        controller.play(tracks[1], in: tracks)
        controller.seek(to: 1)
        controller.previous()

        #expect(controller.currentTrack?.title == "A")
    }

    @Test("Toggling shuffle keeps the current track playing")
    func shuffleKeepsCurrentTrack() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...20).map { makeTrack("T\($0)") }

        controller.play(tracks[7], in: tracks)
        let playing = controller.currentTrack
        controller.shuffleMode = .on

        #expect(controller.currentTrack == playing)
        #expect(controller.queue.count == 20)
        #expect(Set(controller.queue) == Set(tracks))
    }

    @Test("Turning shuffle off restores the original order")
    func unshuffleRestoresOrder() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...10).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        controller.shuffleMode = .on
        controller.shuffleMode = .off

        #expect(controller.queue == tracks)
    }

    @Test("Reshuffling withdraws the prepared track, which is no longer next")
    func reshuffleClearsPreparedTrack() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...10).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        await engine.emit(.started(tracks[0].url))
        controller.shuffleMode = .on

        #expect(engine.clearNextCount >= 1)
    }

    @Test("Up Next reflects the play order, not the album order")
    func upNextFollowsQueue() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]

        controller.play(tracks[0], in: tracks)

        #expect(Array(controller.upNext).map(\.title) == ["B", "C"])
    }

    @Test("Repeat-one replays the same track at its end")
    func repeatOne() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B")]
        controller.repeatMode = .one

        controller.play(tracks[0], in: tracks)
        await engine.emit(.started(tracks[0].url))
        await engine.emit(.finished)

        #expect(controller.currentTrack?.title == "A")
    }

    @Test("A track handed a context it isn't in still plays, rather than nothing")
    func trackOutsideItsContextStillPlays() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let orphan = makeTrack("Orphan")

        controller.play(orphan, in: [makeTrack("A"), makeTrack("B")])

        #expect(controller.currentTrack?.id == orphan.id)
        #expect(engine.played.last?.lastPathComponent == "Orphan.flac")
    }

    @Test("Seeking is clamped to the track")
    func seekClamps() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        // The same value, not two tracks that merely look alike — makeTrack
        // mints a fresh id each call.
        let track = makeTrack("A", seconds: 60)
        controller.play(track, in: [track])
        engine.clearSeeks()

        controller.seek(to: 500)
        controller.seek(to: -10)

        #expect(engine.seeks == [60, 0])
    }

    @Test("An engine failure surfaces rather than being swallowed")
    func failureSurfaces() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let track = makeTrack("A")

        controller.play(track, in: [track])
        await engine.emit(.failed(.fileMissing(track.url)))

        #expect(controller.lastError == .fileMissing(track.url))
    }
}

/// A library is a snapshot of the filesystem, so a file that will not open is
/// the ordinary failure rather than the exceptional one. The record moves on.
@MainActor
@Suite("Unplayable files")
struct PlaybackFailureTests {

    @Test("A track the engine reports failed is skipped, not stopped on")
    func failedTrackIsSkipped() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]

        controller.play(tracks[0], in: tracks)
        await engine.emit(.failed(.unsupportedFormat("FLAC")))

        #expect(controller.currentTrack?.title == "B")
        #expect(controller.state.isActive)
        #expect(controller.skipped.map(\.track.title) == ["A"])
        #expect(controller.notice?.contains("A") == true)
    }

    @Test("A track that will not open at start time falls through to the next")
    func unopenableTrackFallsThrough() {
        let engine = SpyEngine()
        engine.unopenable = ["A.flac", "B.flac"]
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]

        controller.play(tracks[0], in: tracks)

        #expect(controller.currentTrack?.title == "C")
        #expect(controller.skipped.map(\.track.title) == ["A", "B"])
        // Each was genuinely attempted, in order, rather than assumed bad.
        #expect(engine.played.map(\.lastPathComponent) == ["A.flac", "B.flac", "C.flac"])
    }

    @Test("A queue where everything fails stops instead of spinning")
    func allFailedStops() {
        let engine = SpyEngine()
        engine.unopenable = ["A.flac", "B.flac", "C.flac"]
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]

        controller.play(tracks[0], in: tracks)

        #expect(controller.currentTrack == nil)
        #expect(controller.lastError != nil)
        #expect(controller.skipped.count == 3)
        // Three attempts, not four: no track is tried twice.
        #expect(engine.played.count == 3)
    }

    @Test("Repeat One does not re-enter a track the engine refused")
    func repeatOneDoesNotSpinOnAFailure() {
        let engine = SpyEngine()
        engine.unopenable = ["A.flac"]
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B")]
        controller.repeatMode = .one

        controller.play(tracks[0], in: tracks)

        #expect(controller.currentTrack?.title == "B")
        #expect(engine.played.map(\.lastPathComponent) == ["A.flac", "B.flac"])
    }

    @Test("Repeat All wraps past a failure without revisiting it")
    func repeatAllWrapsOnce() {
        let engine = SpyEngine()
        engine.unopenable = ["C.flac"]
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]
        controller.repeatMode = .all

        controller.play(tracks[2], in: tracks)

        #expect(controller.currentTrack?.title == "A")
        #expect(engine.played.map(\.lastPathComponent) == ["C.flac", "A.flac"])
    }

    @Test("A missing file is diagnosed as missing, whatever the engine said")
    func missingFileIsNamedAsSuch() {
        let engine = SpyEngine()
        engine.unopenable = ["A.flac"]
        let controller = PlaybackController(engine: engine)
        // makeTrack points at /music, which does not exist.
        let track = makeTrack("A")

        controller.play(track, in: [track])

        #expect(controller.skipped.first?.reason == .fileMissing(track.url))
    }

    @Test("A file that is present keeps the decoder's own reason")
    func presentFileKeepsEngineReason() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("Corrupt.flac")
        try Data("not audio".utf8).write(to: url)

        let engine = SpyEngine()
        engine.unopenable = ["Corrupt.flac"]
        let controller = PlaybackController(engine: engine)
        var track = makeTrack("Corrupt")
        track.url = url

        controller.play(track, in: [track])

        // The bytes are there and readable, so this is the decoder's verdict
        // and not a file that walked off.
        #expect(controller.skipped.first?.reason == .unsupportedFormat("test"))
    }

    @Test("A prepared track that will not open is skipped rather than stalling")
    func gaplessPreparationSkipsAheadOnFailure() async {
        let engine = SpyEngine()
        engine.unopenable = ["B.flac"]
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]

        controller.play(tracks[0], in: tracks)
        // The handshake starts when the track starts, not near its end.
        await engine.emit(.started(tracks[0].url))

        #expect(controller.currentTrack?.title == "A")
        // B was offered, refused, and C armed in its place — rather than the
        // throw vanishing into a `try?` and surfacing as a gap later.
        #expect(engine.prepared.map(\.lastPathComponent) == ["B.flac", "C.flac"])
        #expect(controller.skipped.map(\.track.title) == ["B"])
    }

    @Test("The skip record outlives the notice, and a new record clears it")
    func skipRecordPersistsUntilNextPlay() {
        let engine = SpyEngine()
        engine.unopenable = ["A.flac"]
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A"), makeTrack("B")]

        controller.play(tracks[0], in: tracks)
        controller.clearNotice()

        #expect(controller.notice == nil)
        #expect(controller.skipped.count == 1)

        engine.unopenable = []
        controller.play(tracks[1], in: tracks)

        #expect(controller.skipped.isEmpty)
    }
}

@MainActor
@Suite("Editing the queue")
struct QueueEditingTests {

    @Test("move matches SwiftUI's onMove semantics", arguments: [
        // (source offsets, destination, expected)
        ([0], 3, ["B", "C", "A", "D"]),
        ([3], 0, ["D", "A", "B", "C"]),
        ([0, 1], 4, ["C", "D", "A", "B"]),
        ([2], 1, ["A", "C", "B", "D"]),
        // A no-op destination leaves the order alone.
        ([1], 1, ["A", "B", "C", "D"]),
    ])
    func move(offsets: [Int], destination: Int, expected: [String]) {
        var items = ["A", "B", "C", "D"]
        Ordering.move(&items, fromOffsets: IndexSet(offsets), toOffset: destination)
        #expect(items == expected)
    }

    @Test("Out-of-range offsets are ignored rather than trapping")
    func moveOutOfRange() {
        var items = ["A", "B"]
        Ordering.move(&items, fromOffsets: IndexSet([5]), toOffset: 0)
        #expect(items == ["A", "B"])
    }

    @Test("Reordering Up Next does not disturb what is playing")
    func reorderKeepsCurrentTrack() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...5).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        // Up Next is T2…T5; move T5 to the front of it.
        controller.moveUpNext(fromOffsets: IndexSet([3]), toOffset: 0)

        #expect(controller.currentTrack?.title == "T1")
        #expect(Array(controller.upNext).map(\.title) == ["T5", "T2", "T3", "T4"])
    }

    @Test("Reordering re-arms the engine with the track that is now next")
    func reorderRequeues() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...4).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        await engine.emit(.started(tracks[0].url))
        #expect(engine.prepared.last?.lastPathComponent == "T2.flac")

        controller.moveUpNext(fromOffsets: IndexSet([2]), toOffset: 0)

        // The engine was holding T2, which is no longer next.
        #expect(engine.clearNextCount >= 1)
        #expect(engine.prepared.last?.lastPathComponent == "T4.flac")
    }

    @Test("Removing from Up Next drops the track and re-arms")
    func removeFromUpNext() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...4).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        await engine.emit(.started(tracks[0].url))
        controller.removeFromUpNext(tracks[1])

        #expect(Array(controller.upNext).map(\.title) == ["T3", "T4"])
        #expect(engine.prepared.last?.lastPathComponent == "T3.flac")
    }

    @Test("Clearing Up Next empties the queue and re-arms with nothing")
    func clearUpNext() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...4).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        await engine.emit(.started(tracks[0].url))
        controller.clearUpNext()

        #expect(controller.currentTrack?.title == "T1")
        #expect(controller.upNext.isEmpty)
        #expect(engine.clearNextCount >= 1)
    }

    @Test("Clearing an already-empty Up Next does nothing")
    func clearUpNextWhenEmpty() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...2).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        controller.jump(to: tracks[1])
        controller.clearUpNext()

        #expect(controller.currentTrack?.title == "T2")
        #expect(controller.queue.count == 2)
    }

    @Test("The playing track cannot be removed from Up Next")
    func cannotRemoveCurrent() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...3).map { makeTrack("T\($0)") }

        controller.play(tracks[1], in: tracks)
        controller.removeFromUpNext(tracks[1])

        #expect(controller.currentTrack?.title == "T2")
        #expect(controller.queue.count == 3)
    }

    @Test("Jumping to a queued track leaves the rest of the queue alone")
    func jump() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...4).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        controller.jump(to: tracks[2])

        #expect(controller.currentTrack?.title == "T3")
        #expect(controller.queue.count == 4)
        #expect(Array(controller.upNext).map(\.title) == ["T4"])
    }

    @Test("Reordering survives a later shuffle toggle")
    func reorderSurvivesUnshuffle() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let tracks = (1...5).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        controller.moveUpNext(fromOffsets: IndexSet([3]), toOffset: 0)
        let reordered = controller.queue

        controller.shuffleMode = .on
        controller.shuffleMode = .off

        // Turning shuffle off restores the order the user last arranged, not
        // the order the album came in.
        #expect(controller.queue == reordered)
    }
}

@MainActor
@Suite("Output device loss")
struct DeviceLossTests {

    @Test("Losing the device pauses rather than carrying on elsewhere")
    func pausesOnDeviceLoss() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let track = makeTrack("A", seconds: 200)

        controller.play(track, in: [track])
        await engine.emit(.started(track.url))
        controller.seek(to: 42)
        await engine.emit(.outputDeviceLost)

        // Audio jumping from headphones to speakers is the thing not to do.
        #expect(!controller.isPlaying)
        #expect(controller.currentTrack?.id == track.id)
        #expect(controller.notice != nil)
    }

    @Test("The position is kept, so resuming picks up where it stopped")
    func keepsPosition() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let track = makeTrack("A", seconds: 200)

        controller.play(track, in: [track])
        await engine.emit(.started(track.url))
        controller.seek(to: 42)
        await engine.emit(.outputDeviceLost)

        let playCountBefore = engine.played.count
        controller.togglePlayPause()

        // Resuming a graph that is no longer connected does nothing at all —
        // the "silently stall" PLAN.md §6 rules out. The track is handed to the
        // engine again instead.
        #expect(engine.played.count == playCountBefore + 1)
        // And specifically NOT resume(), which is the call that would appear to
        // work and produce silence.
        #expect(engine.resumeCount == 0)

        await engine.emit(.started(track.url))
        #expect(engine.seeks.contains(42))
        #expect(controller.notice == nil)
    }

    @Test("Device loss is not an error state — the track is still good")
    func notAnError() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let track = makeTrack("A")

        controller.play(track, in: [track])
        await engine.emit(.started(track.url))
        await engine.emit(.outputDeviceLost)

        #expect(controller.lastError == nil)
    }

    @Test("A notice can be dismissed")
    func dismissNotice() async {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        let track = makeTrack("A")

        controller.play(track, in: [track])
        await engine.emit(.outputDeviceLost)
        controller.clearNotice()
        #expect(controller.notice == nil)
    }
}

@MainActor
@Suite("Mute")
struct MuteTests {

    @Test("Muting silences, unmuting restores the level it had")
    func muteRoundTrip() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        controller.volume = 0.4

        controller.isMuted = true
        #expect(controller.volume == 0)
        #expect(engine.volume == 0)

        controller.isMuted = false
        #expect(abs(controller.volume - 0.4) < 0.0001)
    }

    @Test("Muting twice does not lose the original level")
    func repeatedMute() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        controller.volume = 0.6
        controller.isMuted = true
        controller.isMuted = true
        controller.isMuted = false
        #expect(abs(controller.volume - 0.6) < 0.0001)
    }
}

@MainActor
@Suite("ReplayGain resolution")
struct ReplayGainTests {

    @Test("Album mode prefers the album tag")
    func albumModePrefersAlbumGain() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        controller.replayGainMode = .album
        // trackGain -6, so albumGain is -7.
        let track = makeTrack("A", gain: -6)

        let expected = pow(10.0, -7.0 / 20.0)
        #expect(abs(controller.gain(for: track) - expected) < 0.0001)
    }

    @Test("Track mode prefers the track tag")
    func trackModePrefersTrackGain() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        controller.replayGainMode = .track
        let track = makeTrack("A", gain: -6)

        let expected = pow(10.0, -6.0 / 20.0)
        #expect(abs(controller.gain(for: track) - expected) < 0.0001)
    }

    @Test("Off means unity, whatever the tags say")
    func offIsUnity() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        controller.replayGainMode = .off
        #expect(controller.gain(for: makeTrack("A", gain: -6)) == 1.0)
    }

    @Test("An untagged file plays at unity rather than silence")
    func untaggedIsUnity() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        controller.replayGainMode = .album
        #expect(controller.gain(for: makeTrack("A")) == 1.0)
    }

    @Test("A positive gain is clamped, so a bad tag cannot blow up the output")
    func positiveGainClamped() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine)
        controller.replayGainMode = .track
        #expect(controller.gain(for: makeTrack("A", gain: 12)) == 1.0)
    }
}

@MainActor
@Suite("MockPlayerEngine")
struct MockEngineTests {

    @Test("The clock advances and reports positions")
    func clockAdvances() async throws {
        let engine = MockPlayerEngine(rate: 50)
        let controller = PlaybackController(engine: engine)
        let tracks = [makeTrack("A", seconds: 30), makeTrack("B", seconds: 30)]

        controller.play(tracks[0], in: tracks)
        try await Task.sleep(for: .milliseconds(400))

        #expect(controller.progress.elapsed > 0)
    }

    @Test("Running out of a track with one prepared advances gaplessly")
    func advancesGaplessly() async throws {
        let engine = MockPlayerEngine(rate: 100)
        let controller = PlaybackController(engine: engine)
        // At 100×, a tick covers 10s of audio: A ends on the first tick and B
        // is long enough not to run out before the assertion.
        let tracks = [makeTrack("A", seconds: 5), makeTrack("B", seconds: 600)]

        controller.play(tracks[0], in: tracks)
        try await Task.sleep(for: .milliseconds(400))

        #expect(controller.currentTrack?.title == "B")
        #expect(controller.state.isPlaying)
    }
}

@MainActor
@Suite("Settings persistence")
struct SettingsPersistenceTests {

    @Test("Volume, mute, shuffle, repeat and ReplayGain mode are written as they change")
    func writesOnChange() {
        let settings = InMemorySettingsStore()
        let controller = PlaybackController(engine: SpyEngine(), settings: settings)

        controller.volume = 0.3
        controller.isMuted = true
        controller.shuffleMode = .on
        controller.repeatMode = .all
        controller.replayGainMode = .track

        // Muting drove volume to 0 and banked 0.3 as the level to return to.
        #expect(settings.double(forKey: .volume) == 0)
        #expect(settings.double(forKey: .volumeBeforeMute) == 0.3)
        #expect(settings.bool(forKey: .isMuted) == true)
        #expect(settings.string(forKey: .shuffleMode) == ShuffleMode.on.rawValue)
        #expect(settings.string(forKey: .repeatMode) == RepeatMode.all.rawValue)
        #expect(settings.string(forKey: .replayGainMode) == ReplayGainMode.track.rawValue)
    }

    @Test("A new controller restores volume, shuffle, repeat and ReplayGain mode from settings")
    func restoresPlainState() {
        let settings = InMemorySettingsStore()
        settings.set(0.65, forKey: .volume)
        settings.set(ShuffleMode.on.rawValue, forKey: .shuffleMode)
        settings.set(RepeatMode.all.rawValue, forKey: .repeatMode)
        settings.set(ReplayGainMode.track.rawValue, forKey: .replayGainMode)

        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine, settings: settings)

        #expect(controller.volume == 0.65)
        #expect(engine.volume == 0.65)
        #expect(controller.shuffleMode == .on)
        #expect(controller.repeatMode == .all)
        #expect(controller.replayGainMode == .track)
    }

    @Test("Launching muted restores the level to return to, not zero")
    func restoresMuteWithoutLosingTheLevel() {
        let settings = InMemorySettingsStore()
        settings.set(0.0, forKey: .volume)
        settings.set(true, forKey: .isMuted)
        settings.set(0.8, forKey: .volumeBeforeMute)

        let controller = PlaybackController(engine: SpyEngine(), settings: settings)

        #expect(controller.isMuted)
        #expect(controller.volume == 0)

        controller.isMuted = false
        #expect(controller.volume == 0.8)
    }

    @Test("Restoring muted leaves the settings a second launch reads unchanged")
    func restoringMutedDoesNotRewriteWhatItRead() {
        let settings = InMemorySettingsStore()
        settings.set(0.0, forKey: .volume)
        settings.set(true, forKey: .isMuted)
        settings.set(0.8, forKey: .volumeBeforeMute)

        // Restoring is not a mute: it must not derive `volumeBeforeMute` from
        // the level it just read. Launching twice without touching anything
        // used to walk the saved level up to the compiled-in default, so the
        // second launch had already lost it before the user unmuted.
        _ = PlaybackController(engine: SpyEngine(), settings: settings)

        #expect(settings.double(forKey: .volumeBeforeMute) == 0.8)
        #expect(settings.double(forKey: .volume) == 0.0)
        #expect(settings.bool(forKey: .isMuted) == true)

        let relaunched = PlaybackController(engine: SpyEngine(), settings: settings)
        relaunched.isMuted = false
        #expect(relaunched.volume == 0.8)
    }

    @Test("Muting after an unmuted launch still remembers the restored level")
    func mutingAfterAnUnmutedLaunchKeepsTheRestoredLevel() {
        let settings = InMemorySettingsStore()
        settings.set(0.65, forKey: .volume)
        settings.set(false, forKey: .isMuted)

        // The other direction through `restore`: suppressing the derivation
        // must not leave a controller that cannot derive when the user does
        // reach for the button.
        let controller = PlaybackController(engine: SpyEngine(), settings: settings)
        #expect(controller.volume == 0.65)

        controller.isMuted = true
        #expect(controller.volume == 0)

        controller.isMuted = false
        #expect(controller.volume == 0.65)
    }

    @Test("With nothing persisted, a controller starts at its compiled-in defaults")
    func defaultsWithNothingPersisted() {
        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine, settings: InMemorySettingsStore())

        #expect(controller.volume == 1.0)
        #expect(engine.volume == 1.0)
        #expect(controller.shuffleMode == .off)
        #expect(controller.repeatMode == .off)
        #expect(controller.replayGainMode == .album)
        #expect(!controller.isMuted)
    }
}

@MainActor
@Suite("Queue persistence")
struct QueuePersistenceTests {

    private func encode(_ ids: [Track.ID]) -> String {
        let data = try! JSONEncoder().encode(ids.map(\.uuidString))
        return String(data: data, encoding: .utf8)!
    }

    @Test("Playing a track writes the queue, its order and the current track")
    func playingWritesQueue() {
        let settings = InMemorySettingsStore()
        let controller = PlaybackController(engine: SpyEngine(), settings: settings)
        let tracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]

        controller.play(tracks[1], in: tracks)

        #expect(settings.string(forKey: .queueTrackIDs) == encode(tracks.map(\.id)))
        #expect(settings.string(forKey: .queueOrderedTrackIDs) == encode(tracks.map(\.id)))
        #expect(settings.string(forKey: .queueCurrentTrackID) == tracks[1].id.uuidString)
    }

    @Test("Editing the queue re-writes what's persisted")
    func editingWritesQueue() {
        let settings = InMemorySettingsStore()
        let controller = PlaybackController(engine: SpyEngine(), settings: settings)
        let tracks = (1...3).map { makeTrack("T\($0)") }

        controller.play(tracks[0], in: tracks)
        controller.removeFromUpNext(tracks[1])

        #expect(settings.string(forKey: .queueTrackIDs) == encode([tracks[0].id, tracks[2].id]))
    }

    @Test("flushQueueState writes the exact position immediately, for the app to call on quit")
    func flushWritesPosition() {
        let settings = InMemorySettingsStore()
        let controller = PlaybackController(engine: SpyEngine(), settings: settings)
        let track = makeTrack("A", seconds: 200)

        controller.play(track, in: [track])
        controller.seek(to: 42)
        controller.flushQueueState()

        #expect(settings.double(forKey: .queuePosition) == 42)
    }

    @Test("Restoring puts the queue back paused at the right track, without touching the engine")
    func restoresQueue() {
        let settings = InMemorySettingsStore()
        let tracks = (1...3).map { makeTrack("T\($0)") }
        settings.set(encode(tracks.map(\.id)), forKey: .queueTrackIDs)
        settings.set(encode(tracks.map(\.id)), forKey: .queueOrderedTrackIDs)
        settings.set(tracks[1].id.uuidString, forKey: .queueCurrentTrackID)
        settings.set(65.0, forKey: .queuePosition)

        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine, settings: settings)
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        controller.restoreQueue { byID[$0] }

        #expect(controller.queue == tracks)
        #expect(controller.currentTrack?.id == tracks[1].id)
        #expect(controller.state == .paused(tracks[1].id))
        #expect(controller.progress.elapsed == 65)
        // Nothing was actually handed to the engine — the engine only sees
        // this track once the user presses Play.
        #expect(engine.played.isEmpty)
    }

    @Test("A queue restored from a relaunch keeps the playlist it was started from")
    func restoreKeepsPlaylistOrigin() {
        let settings = InMemorySettingsStore()
        let tracks = (1...3).map { makeTrack("T\($0)") }
        let listID = UUID()

        // Persist as if a playlist had been playing at quit.
        let first = PlaybackController(engine: SpyEngine(), settings: settings)
        first.play(tracks, fromPlaylist: listID)
        first.flushQueueState()
        #expect(settings.string(forKey: .queuePlaylistOrigin) == listID.uuidString)

        // Relaunch.
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let relaunched = PlaybackController(engine: SpyEngine(), settings: settings)
        relaunched.restoreQueue { byID[$0] }

        #expect(relaunched.startedFromPlaylist == listID)
    }

    @Test("A restored queue that was not from a playlist has no origin")
    func restoreWithoutPlaylistOriginIsNil() {
        let settings = InMemorySettingsStore()
        let tracks = (1...2).map { makeTrack("T\($0)") }
        let first = PlaybackController(engine: SpyEngine(), settings: settings)
        first.play(tracks[0], in: tracks)      // an album, say — no playlist
        first.flushQueueState()

        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let relaunched = PlaybackController(engine: SpyEngine(), settings: settings)
        relaunched.restoreQueue { byID[$0] }

        #expect(relaunched.startedFromPlaylist == nil)
    }

    @Test("Pressing Play after a restore reloads the engine at the saved position")
    func resumingAfterRestorePlaysTheEngine() async {
        let settings = InMemorySettingsStore()
        let track = makeTrack("A", seconds: 200)
        settings.set(encode([track.id]), forKey: .queueTrackIDs)
        settings.set(encode([track.id]), forKey: .queueOrderedTrackIDs)
        settings.set(track.id.uuidString, forKey: .queueCurrentTrackID)
        settings.set(80.0, forKey: .queuePosition)

        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine, settings: settings)
        controller.restoreQueue { $0 == track.id ? track : nil }

        controller.togglePlayPause()
        #expect(engine.played.last?.lastPathComponent == "A.flac")

        await engine.emit(.started(track.url))
        #expect(engine.seeks.contains(80))
    }

    @Test("Starting a fresh track after a restore clears the pending resume — Space pauses, not seeks")
    func freshPlayAfterRestoreDoesNotHijackTheFirstPause() async {
        let settings = InMemorySettingsStore()
        let tracks = (1...2).map { makeTrack("T\($0)", seconds: 300) }
        settings.set(encode(tracks.map(\.id)), forKey: .queueTrackIDs)
        settings.set(encode(tracks.map(\.id)), forKey: .queueOrderedTrackIDs)
        settings.set(tracks[0].id.uuidString, forKey: .queueCurrentTrackID)
        settings.set(80.0, forKey: .queuePosition)

        let engine = SpyEngine()
        let controller = PlaybackController(engine: engine, settings: settings)
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        controller.restoreQueue { byID[$0] }

        // The user clicks a track rather than resuming the restored one.
        controller.play(tracks[1], in: tracks)
        await engine.emit(.started(tracks[1].url))
        let playsBeforePause = engine.played.count
        engine.clearSeeks()

        // First Space: it must pause, not reload-and-seek to the stale 80s.
        controller.togglePlayPause()

        #expect(engine.pauseCount == 1)
        #expect(engine.seeks.isEmpty)
        #expect(engine.played.count == playsBeforePause)
    }

    @Test("A track removed from the library since is skipped, landing on the next one")
    func skipsATrackThatNoLongerResolves() {
        let settings = InMemorySettingsStore()
        let tracks = (1...3).map { makeTrack("T\($0)") }
        settings.set(encode(tracks.map(\.id)), forKey: .queueTrackIDs)
        settings.set(encode(tracks.map(\.id)), forKey: .queueOrderedTrackIDs)
        // T2 was playing, but has since left the library outright.
        settings.set(tracks[1].id.uuidString, forKey: .queueCurrentTrackID)
        settings.set(50.0, forKey: .queuePosition)

        let controller = PlaybackController(engine: SpyEngine(), settings: settings)
        var byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        byID[tracks[1].id] = nil
        controller.restoreQueue { byID[$0] }

        #expect(controller.queue.map(\.title) == ["T1", "T3"])
        #expect(controller.currentTrack?.title == "T3")
        // The fallen-through track starts at the top, not at T2's position.
        #expect(controller.progress.elapsed == 0)
    }

    @Test("With nothing persisted, restoring does nothing")
    func restoringWithNothingPersistedDoesNothing() {
        let controller = PlaybackController(engine: SpyEngine(), settings: InMemorySettingsStore())
        controller.restoreQueue { _ in nil }

        #expect(controller.queue.isEmpty)
        #expect(controller.currentTrack == nil)
    }

    @Test("A queue already in progress is left alone rather than clobbered")
    func restoringDoesNotClobberAnActiveQueue() {
        let settings = InMemorySettingsStore()
        let persisted = makeTrack("Persisted")
        settings.set(encode([persisted.id]), forKey: .queueTrackIDs)
        settings.set(persisted.id.uuidString, forKey: .queueCurrentTrackID)

        let controller = PlaybackController(engine: SpyEngine(), settings: settings)
        let live = makeTrack("Live")
        controller.play(live, in: [live])

        controller.restoreQueue { $0 == persisted.id ? persisted : nil }

        #expect(controller.currentTrack?.id == live.id)
    }
}

extension SpyEngine {
    func clearSeeks() { seeks.removeAll() }
}

