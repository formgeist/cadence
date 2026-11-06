import Foundation
import Observation

/// Keeps Cadence's own listening history: watches playback and logs a play once
/// a track has really been listened to. Independent of Last.fm — it records
/// what happens in this app, whether or not scrobbling is on.
///
/// Counts by the same rule scrobbling uses (half the track, or four minutes,
/// whichever is less; nothing under thirty seconds), and only time spent
/// actually playing — paused time and seeks do not count.
@MainActor
@Observable
public final class PlayLogController {
    /// Every logged play, oldest first.
    public private(set) var plays: [PlayRecord] = []

    private let store: any PlayLogStore
    private let now: () -> Date
    private weak var playback: PlaybackController?
    private var pollTask: Task<Void, Never>?

    private var currentTrack: Track?
    private var startedAt = Date()
    private var listened: TimeInterval = 0
    private var lastElapsed: TimeInterval = 0
    private var counted = false

    private static let minimumTrackLength: TimeInterval = 30
    private static let longTrackThreshold: TimeInterval = 240

    public init(store: any PlayLogStore, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Loads the saved history and starts sampling playback.
    public func observe(_ playback: PlaybackController) {
        attach(to: playback)
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.poll()
            }
        }
        Task { await load() }
    }

    func attach(to playback: PlaybackController) { self.playback = playback }

    public func load() async {
        guard let saved = try? await store.allPlays() else { return }
        // Anything logged while the load was in flight is newer than the file.
        let newest = saved.last?.playedAt ?? .distantPast
        plays = saved + plays.filter { $0.playedAt > newest }
    }

    /// Chained onto `playback.onTrackStarted`, so replaying the same track
    /// straight away still starts a fresh count.
    public func trackStarted(_ track: Track) {
        finish()
        begin(track)
    }

    func poll() {
        guard let playback else { return }
        let track = playback.currentTrack
        if track?.id != currentTrack?.id {
            finish()
            if let track { begin(track) }
            return
        }
        let elapsed = playback.progress.elapsed
        if playback.isPlaying {
            let delta = elapsed - lastElapsed
            // Roughly real-time forward motion only: a seek is not listening.
            if delta > 0, delta <= 4 { listened += delta }
        }
        lastElapsed = elapsed
        countIfReady()
    }

    private func begin(_ track: Track) {
        currentTrack = track
        startedAt = now()
        listened = 0
        lastElapsed = playback?.progress.elapsed ?? 0
        counted = false
    }

    private func finish() {
        countIfReady()
        currentTrack = nil
        counted = false
    }

    private func countIfReady() {
        guard !counted, let track = currentTrack,
              track.duration > Self.minimumTrackLength,
              listened >= min(track.duration / 2, Self.longTrackThreshold) else { return }
        counted = true
        let play = PlayRecord(track: track, playedAt: startedAt)
        plays.append(play)
        Task { [store] in try? await store.record(play) }
    }
}
