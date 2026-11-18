import Foundation
import AVFAudio
import SFBAudioEngine
import CadenceCore

/// `PlayerEngine` backed by SFBAudioEngine.
///
/// The whole point of the protocol boundary is that this file is the only one
/// that knows SFB exists — PLAN.md §4, rule 2. Everything above it sees URLs,
/// events and positions.
///
/// Gapless is a handshake, not a flag. `prepareNext` enqueues the following
/// file while the current one is still playing; SFB performs the transition
/// itself and reports it through `nowPlayingChanged`. The controller follows
/// that report rather than driving the change — driving it is what produces a
/// gap.
///
/// **Tracks that are not files yet.** A track from another Mac's library is
/// known by a `cadence-remote://` location, and its `TrackSource` downloads
/// it before there is a file to decode. For those, `play` and `prepareNext`
/// return at once and the work happens in a task: the controller already
/// shows a track as loading until `.started` arrives, and a download that
/// fails arrives as `.failed`, which it handles like any bad file. Events
/// name the location the controller asked for, never the downloaded file.
/// A file URL skips all of this and is played as before, so the Mac's own
/// library is untouched by it.
///
/// Every `play` starts a new generation. A download that finishes after the
/// listener has moved on belongs to an older one and is dropped, so a slow
/// file can never start over the track chosen after it.
@MainActor
public final class SFBPlayerEngine: NSObject, PlayerEngine {

    public let events: AsyncStream<EngineEvent>
    public let positions: AsyncStream<TimeInterval>

    private let eventSink: AsyncStream<EngineEvent>.Continuation
    private let positionSink: AsyncStream<TimeInterval>.Continuation

    private let player = AudioPlayer()
    private var positionTimer: Task<Void, Never>?

    /// The user's volume, independent of ReplayGain. SFB has one output level,
    /// so the two are multiplied before being applied.
    private var userVolume: Double = 1.0
    private var trackGain: Double = 1.0
    /// Set when a track is enqueued for gapless, so its gain can be applied at
    /// the moment SFB actually moves to it.
    private var pendingGain: [URL: Double] = [:]
    private var currentURL: URL?

    // MARK: Tracks fetched by the source

    private let source: any TrackSource
    private var generation = 0
    private var loading: Task<Void, Never>?
    private var preparing: Task<Void, Never>?
    /// The location `preparing` is fetching, so asking twice fetches once.
    private var preparingLocation: URL?
    /// Downloaded file → the location the controller knows it by.
    private var locations: [URL: URL] = [:]

    // MARK: Output sample rate — #34

    private var matchesSampleRate = false
    private let rateMatcher: OutputRateMatcher

    /// Our own rate write makes CoreAudio post a configuration change, which
    /// `audioEngineConfigurationChange` would read as a device being unplugged.
    /// Changes before this instant are ours.
    private var expectsConfigChangeUntil = ContinuousClock.now
    private static let configChangeGrace = Duration.seconds(2)

    /// Position ticks per second. Ten is enough for a smooth scrubber and far
    /// less than a redraw of the whole view tree would cost.
    private static let tickInterval = Duration.milliseconds(100)

    /// - Parameter source: Turns a track's location into a file. The default
    ///   accepts only files, which is all the Mac's own library holds.
    public convenience init(source: any TrackSource = LocalTrackSource()) {
        self.init(rateMatcher: OutputRateMatcher(), source: source)
    }

    init(rateMatcher: OutputRateMatcher, source: any TrackSource = LocalTrackSource()) {
        self.rateMatcher = rateMatcher
        self.source = source
        (events, eventSink) = AsyncStream.makeStream()
        (positions, positionSink) = AsyncStream.makeStream()
        super.init()
        player.delegate = self
    }

    deinit {
        eventSink.finish()
        positionSink.finish()
    }

    // MARK: - PlayerEngine

    public var volume: Double {
        get { userVolume }
        set {
            userVolume = min(max(0, newValue), 1)
            applyVolume()
        }
    }

    public var currentTime: TimeInterval {
        // Nil before the first buffer is rendered, and between tracks.
        player.playbackTime.current ?? 0
    }

    public func play(url: URL, duration: TimeInterval, gain: Double) throws {
        generation += 1
        loading?.cancel()
        cancelPreparing()
        locations.removeAll()

        guard !url.isFileURL else {
            try start(file: url, gain: gain)
            return
        }

        // The listener chose another track: the old one stops now, not when
        // the new one has arrived.
        player.stop()
        currentURL = nil
        pendingGain.removeAll()

        let current = generation
        let source = source
        loading = Task { [weak self] in
            let outcome: Result<URL, PlaybackError>
            do {
                outcome = .success(try await source.fileURL(for: url))
            } catch is CancellationError {
                return
            } catch {
                outcome = .failure(error as? PlaybackError ?? .engine(error.localizedDescription))
            }
            // The controller ignores play and pause while a track loads, so
            // nothing but a newer `play` or a `stop` can have intervened.
            guard let self, self.generation == current else { return }
            do {
                let file = try outcome.get()
                self.locations[file] = url
                try self.start(file: file, gain: gain)
            } catch {
                self.eventSink.yield(.failed(error as? PlaybackError ?? .engine(error.localizedDescription)))
            }
        }
    }

    /// Plays a file that is on disk.
    private func start(file: URL, gain: Double) throws {
        pendingGain.removeAll()
        currentURL = file
        trackGain = gain
        applyVolume()
        matchOutputRate(to: file)

        do {
            try player.play(file)
        } catch {
            throw Self.translate(error, url: file)
        }
        startTicking()
    }

    public func prepareNext(url: URL, duration: TimeInterval, gain: Double) throws {
        guard !url.isFileURL else {
            try enqueueNext(file: url, gain: gain)
            return
        }
        guard preparingLocation != url else { return }
        cancelPreparing()
        preparingLocation = url

        let current = generation
        let source = source
        preparing = Task { [weak self] in
            // A failed download is not an error here. When the current track
            // ends with nothing queued, the controller starts the next one
            // with `play`, and that attempt reports the failure.
            guard let file = try? await source.fileURL(for: url) else { return }
            guard let self, self.generation == current, self.preparingLocation == url,
                  self.currentURL != nil, !Task.isCancelled else { return }
            self.locations[file] = url
            try? self.enqueueNext(file: file, gain: gain)
        }
    }

    private func cancelPreparing() {
        preparing?.cancel()
        preparing = nil
        preparingLocation = nil
    }

    private func enqueueNext(file url: URL, gain: Double) throws {
        // The device cannot change rate under a running stream, and a gapless
        // handoff is exactly a running stream. Where the next file needs a
        // different rate the two cannot both hold, and this picks the rate: the
        // track is left out of the queue, so the current one ends, the
        // controller asks for the next by `play`, and the switch happens then.
        // Same-rate transitions stay gapless.
        if matchesSampleRate, let rate = Self.sampleRate(of: url),
           rateMatcher.needsSwitch(for: rate) {
            return
        }
        pendingGain[url] = gain
        do {
            try player.enqueue(url)
        } catch {
            pendingGain[url] = nil
            throw Self.translate(error, url: url)
        }
    }

    public func clearNext() {
        cancelPreparing()
        player.clearQueue()
        pendingGain.removeAll()
    }

    public func pause() { player.pause() }

    public func resume() { player.resume() }

    public func setOutputSampleRateMatching(_ enabled: Bool) {
        // Turning it off mid-track leaves the device where it is; changing
        // rate under a playing stream is the click this exists to avoid. The
        // rate is put back at the next stop or track change.
        matchesSampleRate = enabled
    }

    public func restoreOutputSampleRate() {
        guard rateMatcher.hasSavedRate else { return }
        player.stop()
        if rateMatcher.restore() { expectConfigChange() }
    }

    public func stop() {
        generation += 1
        loading?.cancel()
        loading = nil
        cancelPreparing()
        locations.removeAll()
        player.stop()
        if rateMatcher.restore() { expectConfigChange() }
        positionTimer?.cancel()
        positionTimer = nil
        currentURL = nil
        pendingGain.removeAll()
    }

    public func seek(to time: TimeInterval) {
        _ = player.seek(time: time)
    }

    // MARK: - Output rate

    /// Runs before the first buffer of a track, with nothing rendering.
    private func matchOutputRate(to url: URL) {
        guard matchesSampleRate else {
            // Matching was turned off while a switched rate was still in force.
            if rateMatcher.hasSavedRate { restoreOutputSampleRate() }
            return
        }
        guard let fileRate = Self.sampleRate(of: url) else { return }

        // Stopping first is what makes the change safe. `play` would stop the
        // old track anyway; it just does so after the rate has moved.
        let switching = rateMatcher.needsSwitch(for: fileRate)
        if switching { player.stop() }

        let outcome = rateMatcher.match(fileRate: fileRate)
        if switching { expectConfigChange() }

        if case .fallback(let deviceRate) = outcome {
            eventSink.yield(.sampleRateNotMatched(fileRate: fileRate, deviceRate: deviceRate))
        }
    }

    private func expectConfigChange() {
        expectsConfigChangeUntil = .now + Self.configChangeGrace
    }

    /// The file's own rate, read without decoding any audio. Nil when the file
    /// cannot be opened; `play` reports that properly a moment later.
    static func sampleRate(of url: URL) -> Double? {
        guard let decoder = try? AudioDecoder(url: url),
              (try? decoder.open()) != nil else { return nil }
        let rate = decoder.processingFormat.sampleRate
        return rate > 0 ? rate : nil
    }

    // MARK: - Volume

    /// SFB exposes a single output level, so ReplayGain is folded into it.
    /// A dedicated gain node in the processing graph would be tidier and is
    /// worth doing if per-track gain ever needs to change mid-playback.
    private func applyVolume() {
        try? player.setVolume(Float(min(userVolume * trackGain, 1.0)))
    }

    // MARK: - Position

    private func startTicking() {
        positionTimer?.cancel()
        positionTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SFBPlayerEngine.tickInterval)
                guard let self else { return }
                guard self.player.isPlaying else { continue }
                guard let current = self.player.playbackTime.current else { continue }
                self.positionSink.yield(current)
            }
        }
    }

    // MARK: - Errors

    private static func translate(_ error: Error, url: URL) -> PlaybackError {
        if !FileManager.default.fileExists(atPath: url.path) {
            return .fileMissing(url)
        }
        let nsError = error as NSError
        // SFB reports an unsupported or unreadable file as a failure to create
        // a decoder for it.
        if nsError.domain == AudioDecoder.ErrorDomain {
            return .unsupportedFormat(url.pathExtension.uppercased())
        }
        return .engine(nsError.localizedDescription)
    }
}

// MARK: - Delegate

extension SFBPlayerEngine: AudioPlayer.Delegate {

    nonisolated public func audioPlayer(
        _ audioPlayer: AudioPlayer, renderingStarted decoder: any PCMDecoding
    ) {
        let url = decoder.inputSource.url
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let url { self.currentURL = url }
            let location = url.map { self.locations[$0] ?? $0 }
            self.eventSink.yield(.started(location ?? URL(fileURLWithPath: "/")))
        }
    }

    /// Decoding a track has begun, which is the earliest safe moment to ask
    /// for the next one — PLAN.md §7.
    nonisolated public func audioPlayer(
        _ audioPlayer: AudioPlayer, decodingStarted decoder: any PCMDecoding
    ) {
        Task { @MainActor [weak self] in
            self?.eventSink.yield(.wantsNextTrack)
        }
    }

    /// SFB moved to the queued track by itself. This is the gapless transition
    /// reported after the fact.
    nonisolated public func audioPlayer(
        _ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: (any PCMDecoding)?
    ) {
        guard let url = nowPlaying?.inputSource.url else { return }
        Task { @MainActor [weak self] in
            guard let self, url != self.currentURL else { return }
            self.currentURL = url
            // Apply the gain that was resolved when this track was enqueued.
            if let gain = self.pendingGain.removeValue(forKey: url) {
                self.trackGain = gain
                self.applyVolume()
            }
            let location = self.locations[url] ?? url
            // Only the file playing now can be reported again.
            self.locations = self.locations.filter { $0.key == url }
            self.preparingLocation = nil
            self.eventSink.yield(.advancedToNext(location))
        }
    }

    nonisolated public func audioPlayer(
        _ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch playbackState {
            case .playing: self.eventSink.yield(.resumed)
            case .paused: self.eventSink.yield(.paused)
            case .stopped: break     // `endOfAudio` carries the meaningful end
            @unknown default: break
            }
        }
    }

    nonisolated public func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        Task { @MainActor [weak self] in
            self?.eventSink.yield(.finished)
        }
    }

    nonisolated public func audioPlayer(
        _ audioPlayer: AudioPlayer, encounteredError error: any Error
    ) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor [weak self] in
            self?.eventSink.yield(.failed(.engine(message)))
        }
    }

    nonisolated public func audioPlayer(
        _ audioPlayer: AudioPlayer,
        decodingAborted decoder: any PCMDecoding,
        error: any Error,
        framesRendered: AVAudioFramePosition
    ) {
        let url = decoder.inputSource.url
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.eventSink.yield(.failed(
                url.map { Self.translate(error, url: $0) } ?? .engine("Decoding failed")))
        }
    }

    /// Headphones unplugged, or the interface disconnected. PLAN.md §6 phase 5
    /// is explicit that this must not crash or silently stall.
    ///
    /// SFB rebuilds its processing graph for the new device. What it cannot do
    /// is decide whether playback should continue somewhere else — so if the
    /// engine did not come back up, the controller is told and pauses.
    nonisolated public func audioPlayer(
        _ audioPlayer: AudioPlayer, audioEngineConfigurationChange userInfo: [AnyHashable: Any]?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A rate switch of our own making is not a device going away.
            guard ContinuousClock.now >= self.expectsConfigChangeUntil else { return }
            // Give the graph a moment to come back before calling it lost.
            try? await Task.sleep(for: .milliseconds(250))
            guard !self.player.isPlaying else { return }
            self.eventSink.yield(.outputDeviceLost)
        }
    }
}
