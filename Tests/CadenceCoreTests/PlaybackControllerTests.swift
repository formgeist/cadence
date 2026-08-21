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

    func play(url: URL, duration: TimeInterval, gain: Double) throws {
        played.append(url)
        gains.append(gain)
    }

    func prepareNext(url: URL, duration: TimeInterval, gain: Double) throws {
        prepared.append(url)
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

extension SpyEngine {
    func clearSeeks() { seeks.removeAll() }
}

