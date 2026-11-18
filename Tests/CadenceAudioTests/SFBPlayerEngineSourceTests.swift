import Testing
import Foundation
import CadenceCore
@testable import CadenceAudio

/// Short silent WAV files, written once per test.
private func silence(seconds: Double, in directory: URL, named name: String) throws -> URL {
    let rate = 44_100, channels = 2, bytesPerSample = 2
    let frames = Int(Double(rate) * seconds)
    let dataSize = frames * channels * bytesPerSample
    var header = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
    }
    header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
    header.append(contentsOf: Array("WAVE".utf8))
    header.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1))
    append(UInt16(channels)); append(UInt32(rate))
    append(UInt32(rate * channels * bytesPerSample)); append(UInt16(channels * bytesPerSample))
    append(UInt16(bytesPerSample * 8))
    header.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
    let url = directory.appendingPathComponent(name)
    try (header + Data(count: dataSize)).write(to: url)
    return url
}

/// Hands out files for `cadence-remote://` locations after a delay, or
/// fails, the way a download would. Counts what it was asked.
private actor ScriptedSource: TrackSource {
    private var files: [URL: URL] = [:]
    private var delays: [URL: Duration] = [:]
    private var failures: [URL: PlaybackError] = [:]
    private(set) var asked: [URL] = []

    func serve(_ location: URL, file: URL, after delay: Duration = .zero) {
        files[location] = file
        delays[location] = delay
    }

    func fail(_ location: URL, with error: PlaybackError) { failures[location] = error }

    func fileURL(for location: URL) async throws -> URL {
        asked.append(location)
        if let delay = delays[location], delay > .zero { try await Task.sleep(for: delay) }
        if let failure = failures[location] { throw failure }
        guard let file = files[location] else { throw PlaybackError.engine("Unknown") }
        return file
    }
}

/// Every event the engine sends, in order.
@MainActor
private final class EventLog {
    private(set) var events: [EngineEvent] = []
    private var task: Task<Void, Never>?

    init(_ engine: SFBPlayerEngine) {
        task = Task { [weak self] in
            for await event in engine.events { self?.events.append(event) }
        }
    }

    deinit { task?.cancel() }

    /// Waits until an event matching `match` has arrived, or the time is up.
    func wait(for seconds: Double = 5, _ match: (EngineEvent) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if events.contains(where: match) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    var started: [URL] { events.compactMap { if case .started(let url) = $0 { url } else { nil } } }
}

private func location(_ name: String) -> URL { URL(string: "cadence-remote://song/tr-\(name)?suffix=wav")! }

/// The engine opens the real output device, which a build machine may not
/// have.
private let hasOutputDevice = (try? OutputDevice.defaultOutputDeviceID()) != nil

@MainActor
@Suite("SFBPlayerEngine with a track source", .serialized, .enabled(if: hasOutputDevice))
struct SFBPlayerEngineSourceTests {

    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test("A remote track starts once fetched, reported by its location")
    func startsRemote() async throws {
        let source = ScriptedSource()
        let a = location("a")
        await source.serve(a, file: try silence(seconds: 2, in: directory, named: "a.wav"),
                           after: .milliseconds(200))
        let engine = SFBPlayerEngine(source: source)
        let log = EventLog(engine)
        defer { engine.stop() }

        try engine.play(url: a, duration: 2, gain: 1)
        #expect(await log.wait { $0 == .started(a) })
        #expect(await source.asked == [a])
        #expect(!log.started.contains { $0.isFileURL })
    }

    @Test("A track chosen while another is fetched wins")
    func newerPlayWins() async throws {
        let source = ScriptedSource()
        let slow = location("slow"), fast = location("fast")
        await source.serve(slow, file: try silence(seconds: 2, in: directory, named: "slow.wav"),
                           after: .milliseconds(400))
        await source.serve(fast, file: try silence(seconds: 2, in: directory, named: "fast.wav"))
        let engine = SFBPlayerEngine(source: source)
        let log = EventLog(engine)
        defer { engine.stop() }

        try engine.play(url: slow, duration: 2, gain: 1)
        try engine.play(url: fast, duration: 2, gain: 1)
        #expect(await log.wait { $0 == .started(fast) })
        // Past the slow file's arrival: it must not have started over.
        try await Task.sleep(for: .milliseconds(600))
        #expect(log.started == [fast])
    }

    @Test("Stopping while a track is fetched leaves nothing to start")
    func stopDuringFetch() async throws {
        let source = ScriptedSource()
        let a = location("a")
        await source.serve(a, file: try silence(seconds: 2, in: directory, named: "a.wav"),
                           after: .milliseconds(200))
        let engine = SFBPlayerEngine(source: source)
        let log = EventLog(engine)

        try engine.play(url: a, duration: 2, gain: 1)
        engine.stop()
        try await Task.sleep(for: .milliseconds(500))
        #expect(log.started.isEmpty)
    }

    @Test("A download that fails is reported as the source's error")
    func failure() async throws {
        let source = ScriptedSource()
        let a = location("a")
        await source.fail(a, with: .engine("The Mac is not answering."))
        let engine = SFBPlayerEngine(source: source)
        let log = EventLog(engine)
        defer { engine.stop() }

        try engine.play(url: a, duration: 2, gain: 1)
        #expect(await log.wait { $0 == .failed(.engine("The Mac is not answering.")) })
        #expect(log.started.isEmpty)
    }

    @Test("The next remote track is fetched ahead and played without a restart")
    func gapless() async throws {
        let source = ScriptedSource()
        let a = location("a"), b = location("b")
        await source.serve(a, file: try silence(seconds: 0.6, in: directory, named: "a.wav"))
        await source.serve(b, file: try silence(seconds: 2, in: directory, named: "b.wav"),
                           after: .milliseconds(100))
        let engine = SFBPlayerEngine(source: source)
        let log = EventLog(engine)
        defer { engine.stop() }

        try engine.play(url: a, duration: 0.6, gain: 1)
        #expect(await log.wait { $0 == .wantsNextTrack })
        try engine.prepareNext(url: b, duration: 2, gain: 1)
        // Asked twice, as the controller may; fetched once.
        try engine.prepareNext(url: b, duration: 2, gain: 1)

        #expect(await log.wait { $0 == .advancedToNext(b) })
        #expect(!log.events.contains(.finished))
        #expect(await source.asked == [a, b])
    }

    @Test("A file is played as before, without asking the source")
    func localFile() async throws {
        let source = ScriptedSource()
        let file = try silence(seconds: 2, in: directory, named: "local.wav")
        let engine = SFBPlayerEngine(source: source)
        let log = EventLog(engine)
        defer { engine.stop() }

        try engine.play(url: file, duration: 2, gain: 1)
        #expect(await log.wait { $0 == .started(file) })
        #expect(await source.asked.isEmpty)
    }
}
