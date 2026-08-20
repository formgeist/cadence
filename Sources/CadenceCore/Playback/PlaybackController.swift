import Foundation
import Observation

/// The single object every view binds to. Owns the queue, the play modes, and
/// the gapless handshake with whatever `PlayerEngine` it was handed.
///
/// Views never see an engine implementation type — see PLAN.md §4, rule 2.
@MainActor
@Observable
public final class PlaybackController {

    // MARK: State

    public private(set) var state: PlaybackState = .idle
    /// Separate from `state` on purpose: this changes ten times a second.
    public private(set) var progress: PlaybackProgress = .zero

    /// The queue in play order. Under shuffle this is already shuffled, so the
    /// queue view shows what will genuinely happen next.
    public private(set) var queue: [Track] = []
    public private(set) var currentIndex: Int?

    public var repeatMode: RepeatMode = .off
    public var replayGainMode: ReplayGainMode = .album {
        didSet { applyGainToCurrent() }
    }

    public var shuffleMode: ShuffleMode = .off {
        didSet {
            guard oldValue != shuffleMode else { return }
            reshuffleAroundCurrent()
        }
    }

    public var volume: Double = 1.0 {
        didSet { engine.volume = volume }
    }

    // MARK: Derived

    public var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// What the "Up Next" list shows — everything after the current track.
    public var upNext: ArraySlice<Track> {
        guard let currentIndex, currentIndex + 1 < queue.count else { return [] }
        return queue[(currentIndex + 1)...]
    }

    public var isPlaying: Bool { state.isPlaying }

    public var lastError: PlaybackError? {
        if case .failed(let error) = state { return error }
        return nil
    }

    // MARK: Private

    private let engine: any PlayerEngine
    /// The queue in the order it was handed to us, so turning shuffle off can
    /// restore it rather than re-sorting a shuffled list.
    private var orderedQueue: [Track] = []
    /// Set once we've handed the engine a next track, so we don't do it twice.
    private var preparedNext: Track.ID?
    // Both loops capture self weakly and return once it is gone, so they
    // need no cancellation from deinit — which could not touch them anyway,
    // this class being MainActor-isolated.
    private var eventTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?

    public init(engine: any PlayerEngine) {
        self.engine = engine
        engine.volume = volume
        observe()
    }

    private func observe() {
        eventTask = Task { [weak self, events = engine.events] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        positionTask = Task { [weak self, positions = engine.positions] in
            for await time in positions {
                guard let self else { return }
                self.progress.elapsed = time
            }
        }
    }

    // MARK: - Starting playback

    /// Play `track` in the context of `tracks` — clicking row 3 of an album
    /// queues the whole album and starts at 3.
    public func play(_ track: Track, in tracks: [Track]) {
        orderedQueue = tracks
        queue = shuffleMode.isOn ? Self.shuffled(tracks, startingWith: track) : tracks
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else {
            // The track isn't in the context it was handed. Rather than
            // silently doing nothing, play it on its own.
            orderedQueue = [track]
            queue = [track]
            start(at: 0)
            return
        }
        start(at: index)
    }

    public func play(_ album: Album) {
        let ordered = album.discs.flatMap(\.tracks)
        guard let first = ordered.first else { return }
        play(first, in: ordered)
    }

    /// Queue an album with shuffle forced on, for the album header's Shuffle
    /// button. Leaves the user's own shuffle setting flipped, because that is
    /// what the button visibly did.
    public func shuffle(_ album: Album) {
        let ordered = album.discs.flatMap(\.tracks)
        guard !ordered.isEmpty else { return }
        shuffleMode = .on
        orderedQueue = ordered
        queue = ordered.shuffled()
        start(at: 0)
    }

    public func appendToQueue(_ tracks: [Track]) {
        orderedQueue.append(contentsOf: tracks)
        queue.append(contentsOf: tracks)
        // A track appended after the current one may now be the gapless
        // candidate the engine hasn't been told about.
        prepareNextIfNeeded()
    }

    private func start(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        let track = queue[index]
        state = .loading(track.id)
        progress = PlaybackProgress(elapsed: 0, duration: track.duration)
        preparedNext = nil

        do {
            try engine.play(url: track.url, duration: track.duration, gain: gain(for: track))
        } catch let error as PlaybackError {
            state = .failed(error)
        } catch {
            state = .failed(.engine(error.localizedDescription))
        }
    }

    // MARK: - Transport

    public func togglePlayPause() {
        switch state {
        case .playing: engine.pause()
        case .paused: engine.resume()
        case .idle, .failed:
            // Nothing loaded — start the queue from the top if there is one.
            if currentIndex == nil, !queue.isEmpty { start(at: 0) }
        case .loading:
            break
        }
    }

    public func next() {
        guard let index = indexAfter(currentIndex) else {
            stop()
            return
        }
        start(at: index)
    }

    /// Restarts the current track when more than a few seconds in, the way
    /// every other player behaves.
    public func previous() {
        if progress.elapsed > 3 {
            seek(to: 0)
            return
        }
        guard let currentIndex, currentIndex > 0 else {
            seek(to: 0)
            return
        }
        start(at: currentIndex - 1)
    }

    public func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), progress.duration)
        progress.elapsed = clamped
        engine.seek(to: clamped)
    }

    public func seek(toFraction fraction: Double) {
        seek(to: progress.duration * min(max(0, fraction), 1))
    }

    public func stop() {
        engine.stop()
        state = .idle
        progress = .zero
        currentIndex = nil
        preparedNext = nil
    }

    public func toggleShuffle() { shuffleMode = shuffleMode.toggled }
    public func cycleRepeat() { repeatMode = repeatMode.next }

    // MARK: - Queue order

    private func indexAfter(_ index: Int?) -> Int? {
        guard let index else { return queue.isEmpty ? nil : 0 }
        if repeatMode == .one { return index }
        let next = index + 1
        if queue.indices.contains(next) { return next }
        return repeatMode == .all && !queue.isEmpty ? 0 : nil
    }

    /// Keeps the current track in place and shuffles everything around it, so
    /// toggling shuffle mid-song doesn't interrupt what's playing.
    private func reshuffleAroundCurrent() {
        guard let current = currentTrack else {
            queue = shuffleMode.isOn ? orderedQueue.shuffled() : orderedQueue
            return
        }
        queue = shuffleMode.isOn
            ? Self.shuffled(orderedQueue, startingWith: current)
            : orderedQueue
        currentIndex = queue.firstIndex { $0.id == current.id }
        // The track after the current one just changed; the engine is holding
        // a stale one.
        preparedNext = nil
        engine.clearNext()
        prepareNextIfNeeded()
    }

    private static func shuffled(_ tracks: [Track], startingWith track: Track) -> [Track] {
        var rest = tracks
        rest.removeAll { $0.id == track.id }
        return [track] + rest.shuffled()
    }

    // MARK: - Gapless

    /// Called the moment a track *starts*, not near its end. SFB then performs
    /// the transition itself and reports it; getting this backwards produces a
    /// gap. See PLAN.md §7.
    private func prepareNextIfNeeded() {
        guard state.isActive, let index = indexAfter(currentIndex),
              queue.indices.contains(index) else { return }
        let track = queue[index]
        guard preparedNext != track.id else { return }
        preparedNext = track.id
        try? engine.prepareNext(url: track.url, duration: track.duration, gain: gain(for: track))
    }

    // MARK: - ReplayGain

    /// Linear amplitude the engine should apply. Clamped so a badly tagged
    /// file with +12 dB can't blow the output up.
    public func gain(for track: Track) -> Double {
        let decibels: Double? = switch replayGainMode {
        case .off: nil
        case .track: track.replayGain?.trackGain ?? track.replayGain?.albumGain
        case .album: track.replayGain?.albumGain ?? track.replayGain?.trackGain
        }
        guard let decibels else { return 1.0 }
        return min(pow(10, decibels / 20), 1.0)
    }

    private func applyGainToCurrent() {
        // The engine reads gain at play time, so the mode change lands on the
        // next track rather than jumping the level mid-song. The prepared
        // track does need re-arming with the new value.
        preparedNext = nil
        engine.clearNext()
        prepareNextIfNeeded()
    }

    // MARK: - Engine events

    private func handle(_ event: EngineEvent) {
        switch event {
        case .started:
            if let track = currentTrack {
                state = .playing(track.id)
                progress.duration = track.duration
            }
            prepareNextIfNeeded()

        case .resumed:
            if let track = currentTrack { state = .playing(track.id) }

        case .paused:
            if let track = currentTrack { state = .paused(track.id) }

        case .wantsNextTrack:
            prepareNextIfNeeded()

        case .advancedToNext(let url):
            // The engine moved on by itself. Follow it rather than restarting
            // the track, which would re-decode and produce the gap we just
            // avoided.
            let expected = preparedNext
            let index = queue.firstIndex { $0.id == expected }
                ?? queue.firstIndex { $0.url == url }
            if let index {
                currentIndex = index
                let track = queue[index]
                state = .playing(track.id)
                progress = PlaybackProgress(elapsed: 0, duration: track.duration)
                preparedNext = nil
                prepareNextIfNeeded()
            }

        case .finished:
            if let index = indexAfter(currentIndex), index != currentIndex {
                start(at: index)
            } else if repeatMode == .one, let currentIndex {
                start(at: currentIndex)
            } else {
                stop()
            }

        case .failed(let error):
            state = .failed(error)
            progress = .zero
        }
    }
}
