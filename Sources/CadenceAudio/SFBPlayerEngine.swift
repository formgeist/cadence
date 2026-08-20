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

    /// Position ticks per second. Ten is enough for a smooth scrubber and far
    /// less than a redraw of the whole view tree would cost.
    private static let tickInterval = Duration.milliseconds(100)

    public override init() {
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
        pendingGain.removeAll()
        currentURL = url
        trackGain = gain
        applyVolume()

        do {
            try player.play(url)
        } catch {
            throw Self.translate(error, url: url)
        }
        startTicking()
    }

    public func prepareNext(url: URL, duration: TimeInterval, gain: Double) throws {
        pendingGain[url] = gain
        do {
            try player.enqueue(url)
        } catch {
            pendingGain[url] = nil
            throw Self.translate(error, url: url)
        }
    }

    public func clearNext() {
        player.clearQueue()
        pendingGain.removeAll()
    }

    public func pause() { player.pause() }

    public func resume() { player.resume() }

    public func stop() {
        player.stop()
        positionTimer?.cancel()
        positionTimer = nil
        currentURL = nil
        pendingGain.removeAll()
    }

    public func seek(to time: TimeInterval) {
        _ = player.seek(time: time)
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
            self.eventSink.yield(.started(url ?? URL(fileURLWithPath: "/")))
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
            self.eventSink.yield(.advancedToNext(url))
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

    /// Headphones unplugged, or the output device disappeared. PLAN.md §6
    /// phase 5 is explicit that this must not crash or silently stall.
    nonisolated public func audioPlayer(
        _ audioPlayer: AudioPlayer, audioEngineConfigurationChange userInfo: [AnyHashable: Any]?
    ) {
        Task { @MainActor [weak self] in
            guard let self, !self.player.engineIsRunning else { return }
            self.eventSink.yield(.failed(.outputDeviceLost))
        }
    }
}
