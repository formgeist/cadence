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

    public var repeatMode: RepeatMode = .off {
        didSet { settings.set(repeatMode.rawValue, forKey: .repeatMode) }
    }
    public var replayGainMode: ReplayGainMode = .album {
        didSet {
            applyGainToCurrent()
            settings.set(replayGainMode.rawValue, forKey: .replayGainMode)
        }
    }

    public var shuffleMode: ShuffleMode = .off {
        didSet {
            settings.set(shuffleMode.rawValue, forKey: .shuffleMode)
            guard oldValue != shuffleMode else { return }
            reshuffleAroundCurrent()
        }
    }

    public var volume: Double = 1.0 {
        didSet {
            engine.volume = volume
            settings.set(volume, forKey: .volume)
        }
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

    /// A passing message for the interface — not an error state. Cleared by the
    /// next thing the user does.
    public private(set) var notice: String?

    /// Whether `notice` reports a state the user should acknowledge rather than
    /// a message that can time out — set for the output-device change, which
    /// leaves playback paused until they act on it. The interface reads this to
    /// decide whether to auto-dismiss the banner.
    public private(set) var noticeIsSticky = false

    /// Fired the instant a track actually starts, whether that's a fresh
    /// `play(_:in:)` or a gapless handoff the engine made on its own — never
    /// on queuing alone. The composition root wires this to record play
    /// history; `PlaybackController` itself knows nothing about persistence.
    /// See #72.
    public var onTrackStarted: ((Track) -> Void)?

    public func clearNotice() {
        notice = nil
        noticeIsSticky = false
    }

    /// Tracks the queue moved past because the engine could not play them.
    ///
    /// Separate from `notice` on purpose: a notice is gone the moment the user
    /// dismisses it or the next one lands, and a record that quietly dropped
    /// four tracks is barely better than one that stopped on the first. This
    /// list survives until playback is deliberately started again, so the
    /// interface can still answer "what did it skip?" after the fact.
    public private(set) var skipped: [SkippedTrack] = []

    /// Ids in `skipped`, for the O(1) membership the queue walk needs.
    private var failedIDs: Set<Track.ID> = []

    public func clearSkipped() {
        skipped = []
        failedIDs = []
    }

    /// Set when the output device disappeared and the engine has to be handed
    /// the file again before it can play. Resuming a dead graph silently does
    /// nothing, which is exactly the "silently stall" PLAN.md §6 rules out.
    ///
    /// Also set by `restoreQueue(resolving:)`: a restored queue is paused at
    /// a track the engine has never actually been handed, so the same reload
    /// — rather than `engine.resume()` on nothing — is what has to happen
    /// the first time the user presses Play. See #42.
    private var needsReloadAtPosition: TimeInterval?
    /// Read from settings at init, but not applied — `PlaybackController` has
    /// no reach into the library (PLAN.md §5), so an id is all it can hold
    /// onto until the composition root calls `restoreQueue(resolving:)` with
    /// real `Track`s. See #42.
    private var pendingRestoreQueueIDs: [Track.ID] = []
    private var pendingRestoreOrderedQueueIDs: [Track.ID] = []
    private var pendingRestoreCurrentTrackID: Track.ID?
    private var pendingRestorePosition: TimeInterval = 0
    /// Throttles `persistPositionIfDue`, so a five-second gap between writes
    /// survives a position stream that ticks ten times a second.
    private var lastPersistedPositionSecond: Int?

    // MARK: Private

    private let engine: any PlayerEngine
    private let settings: any SettingsStore
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

    public init(engine: any PlayerEngine, settings: any SettingsStore = InMemorySettingsStore()) {
        self.engine = engine
        self.settings = settings
        restore(from: settings)
        observe()
    }

    /// Assigns the persisted values without letting `isMuted`'s `didSet`
    /// derive any of them — see `isRestoringSettings`. Every value here is
    /// already known, so nothing needs recomputing from anything else, and
    /// the order these run in does not matter.
    private func restore(from settings: any SettingsStore) {
        isRestoringSettings = true
        defer { isRestoringSettings = false }

        if let raw = settings.string(forKey: .repeatMode), let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        if let raw = settings.string(forKey: .shuffleMode), let mode = ShuffleMode(rawValue: raw) {
            shuffleMode = mode
        }
        if let raw = settings.string(forKey: .replayGainMode),
           let mode = ReplayGainMode(rawValue: raw) {
            replayGainMode = mode
        }
        if let muted = settings.bool(forKey: .isMuted) {
            isMuted = muted
        }
        if let level = settings.double(forKey: .volumeBeforeMute) {
            volumeBeforeMute = level
        }
        if let level = settings.double(forKey: .volume) {
            volume = level
        } else {
            engine.volume = volume
        }
        pendingRestoreQueueIDs = Self.decode(settings.string(forKey: .queueTrackIDs))
            .compactMap(UUID.init)
        pendingRestoreOrderedQueueIDs = Self.decode(settings.string(forKey: .queueOrderedTrackIDs))
            .compactMap(UUID.init)
        pendingRestoreCurrentTrackID = settings.string(forKey: .queueCurrentTrackID)
            .flatMap(UUID.init)
        pendingRestorePosition = settings.double(forKey: .queuePosition) ?? 0
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
                self.persistPositionIfDue(time)
            }
        }
    }

    // MARK: - Starting playback

    /// Play `track` in the context of `tracks` — clicking row 3 of an album
    /// queues the whole album and starts at 3.
    public func play(_ track: Track, in tracks: [Track]) {
        // A new record is a fresh chance for every file: the NAS may be back,
        // and the user asked for these tracks rather than inheriting a verdict
        // from the last queue.
        clearSkipped()
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
        shuffle(album.discs.flatMap(\.tracks))
    }

    /// The same, over any run of tracks — an artist's whole discography, say.
    public func shuffle(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        clearSkipped()
        shuffleMode = .on
        orderedQueue = tracks
        queue = tracks.shuffled()
        start(at: 0)
    }

    // MARK: - Editing the queue

    /// Reorders the queue. Offsets are into `upNext`, which is what the queue
    /// view shows, so the caller never has to reason about where the currently
    /// playing track sits.
    public func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let currentIndex else { return }
        let head = currentIndex + 1
        guard head < queue.count else { return }

        var upcoming = Array(queue[head...])
        Ordering.move(&upcoming, fromOffsets: source, toOffset: destination)
        queue.replaceSubrange(head..., with: upcoming)

        // Keep the unshuffled order in step, so turning shuffle off later does
        // not silently undo the reordering the user just did.
        if !shuffleMode.isOn { orderedQueue = queue }

        requeueNext()
        persistQueue()
    }

    /// Removes a track from what is coming up. Removing the playing track is
    /// deliberately not possible here — that is what `next()` is for.
    public func removeFromUpNext(_ track: Track) {
        guard let currentIndex,
              let index = queue.firstIndex(where: { $0.id == track.id }),
              index > currentIndex else { return }
        queue.remove(at: index)
        orderedQueue.removeAll { $0.id == track.id }
        requeueNext()
        persistQueue()
    }

    /// Empties everything queued after the current track. Playback itself is
    /// untouched — this is "forget what's next," not `stop()`.
    public func clearUpNext() {
        guard let currentIndex, currentIndex + 1 < queue.count else { return }
        let removedIDs = Set(queue[(currentIndex + 1)...].map(\.id))
        queue.removeSubrange((currentIndex + 1)...)
        orderedQueue.removeAll { removedIDs.contains($0.id) }
        requeueNext()
        persistQueue()
    }

    /// Plays something already in the queue, without disturbing the rest of it.
    public func jump(to track: Track) {
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        // Picking a track by hand overrides an earlier skip. Clearing only this
        // one keeps the rest of the record intact, so a queue that dropped four
        // files still says so after the user retries one of them.
        forget(track.id)
        start(at: index)
    }

    private func forget(_ id: Track.ID) {
        guard failedIDs.remove(id) != nil else { return }
        skipped.removeAll { $0.id == id }
    }

    /// The track after the current one may have changed; withdraw whatever the
    /// engine is holding and hand it the right one.
    private func requeueNext() {
        preparedNext = nil
        engine.clearNext()
        prepareNextIfNeeded()
    }

    public func appendToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        orderedQueue.append(contentsOf: tracks)
        queue.append(contentsOf: tracks)
        // A track appended after the current one may now be the gapless
        // candidate the engine hasn't been told about.
        prepareNextIfNeeded()
        persistQueue()
        // The queue lives in the Now Playing pane, which is often closed when
        // this runs from an album or playlist menu — without a word it is
        // indistinguishable from a dead menu item, the same as a playlist add.
        let count = tracks.count == 1 ? "1 track" : "\(tracks.count) tracks"
        notice = "Added \(count) to the queue"
        noticeIsSticky = false
    }

    /// Loops rather than recurses on failure. A queue of thirty thousand tracks
    /// on an unmounted volume fails thirty thousand times in a row, and a
    /// recursive skip would take the stack out before it reached the end.
    private func start(at index: Int, resumingAt position: TimeInterval? = nil) {
        var index = index
        var position = position

        // Committing to a track at a known position supersedes any deferred
        // "reload where you left off" — from `restoreQueue` or a lost output
        // device. Left set, a stale one hijacked the first `togglePlayPause`
        // after the user started a different track: instead of pausing, the
        // track reloaded and seeked to the old position.
        needsReloadAtPosition = nil

        while queue.indices.contains(index) {
            let track = queue[index]
            currentIndex = index
            state = .loading(track.id)
            progress = PlaybackProgress(elapsed: position ?? 0, duration: track.duration)
            preparedNext = nil
            pendingSeek = position

            do {
                try engine.play(url: track.url, duration: track.duration,
                                gain: gain(for: track))
                persistQueue()
                return
            } catch {
                // A file that will not open is the ordinary failure for a
                // library that mirrors the filesystem, not an exceptional one.
                // Move on rather than stopping the record here.
                note(skip: track, reason: PlaybackError.diagnosing(error, at: track.url))
                guard let next = indexAfter(index) else {
                    stopAfterFailures()
                    return
                }
                index = next
                // Only the track the user actually asked to resume gets its
                // position back; the one we fell through to starts at the top.
                position = nil
            }
        }
    }

    /// Applied once the engine reports the track started; seeking before that
    /// lands on a file the engine has not opened yet.
    private var pendingSeek: TimeInterval?

    // MARK: - Transport

    public func togglePlayPause() {
        // The device came back, or the user picked another one. Start the track
        // again where it left off rather than resuming an engine that is no
        // longer connected to anything.
        if let position = needsReloadAtPosition, let index = currentIndex {
            needsReloadAtPosition = nil
            notice = nil
            noticeIsSticky = false
            start(at: index, resumingAt: position)
            return
        }

        switch state {
        case .playing: engine.pause()
        case .paused: engine.resume()
        case .idle, .failed:
            // Nothing loaded — start the queue from the top if there is one.
            // Pressing Play after a queue died is a deliberate retry, so the
            // earlier verdicts go with it; the volume may well be back.
            if currentIndex == nil, !queue.isEmpty {
                clearSkipped()
                start(at: 0)
            }
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
        needsReloadAtPosition = nil
        pendingSeek = nil
        persistQueue()
    }

    public func toggleShuffle() { shuffleMode = shuffleMode.toggled }
    public func cycleRepeat() { repeatMode = repeatMode.next }

    // MARK: - Queue order

    private func indexAfter(_ index: Int?) -> Int? {
        guard let index else { return nextPlayableIndex(after: -1, wrapping: false) }
        // Repeat One holds on the current track — unless the engine has already
        // refused that track, in which case holding on it is a spin the user
        // can only break by hand. A dead file under Repeat One moves on and
        // then stops, rather than looping over a failure forever.
        if repeatMode == .one, queue.indices.contains(index),
           !failedIDs.contains(queue[index].id) {
            return index
        }
        return nextPlayableIndex(after: index, wrapping: repeatMode == .all)
    }

    /// The first index after `index` whose track has not already failed.
    /// `wrapping` returns to the top of the queue once, for Repeat All.
    ///
    /// Stepping over known-bad tracks is what stops a queue of dead files from
    /// spinning: every walk is bounded by `queue.count`, and each failure
    /// shortens the next one.
    private func nextPlayableIndex(after index: Int, wrapping: Bool) -> Int? {
        guard !queue.isEmpty else { return nil }
        for step in 1...queue.count {
            let raw = index + step
            guard raw < queue.count || wrapping else { return nil }
            let candidate = raw % queue.count
            if !failedIDs.contains(queue[candidate].id) { return candidate }
        }
        return nil
    }

    // MARK: - Failures

    /// Records a track the engine could not play, and says so once. Repeated
    /// failures on the same track — Repeat All coming round again — count once.
    private func note(skip track: Track, reason: PlaybackError) {
        guard failedIDs.insert(track.id).inserted else { return }
        skipped.append(SkippedTrack(track: track, reason: reason))
        notice = Self.skipNotice(for: skipped)
        noticeIsSticky = false
    }

    /// Every remaining track failed too. Stop, but end in `.failed` rather than
    /// `.idle` so the reason stays on screen — an idle transport after a queue
    /// of dead files says nothing about why nothing played.
    private func stopAfterFailures() {
        let reason = skipped.last?.reason ?? .engine("Nothing in the queue could be played.")
        stop()
        // The notice would otherwise sit in front of the error that explains
        // the stop; `skipped` still carries the count.
        notice = nil
        noticeIsSticky = false
        state = .failed(reason)
    }

    private static func skipNotice(for skipped: [SkippedTrack]) -> String {
        guard let last = skipped.last else { return "" }
        let line = "Skipped “\(last.track.title)” — \(last.reason.reasonPhrase)"
        return skipped.count > 1 ? "\(line) (\(skipped.count) skipped)" : line
    }

    /// Keeps the current track in place and shuffles everything around it, so
    /// toggling shuffle mid-song doesn't interrupt what's playing.
    /// 0…1. Kept separate from ReplayGain, which the engine folds in itself.
    public var isMuted: Bool = false {
        didSet {
            settings.set(isMuted, forKey: .isMuted)
            guard !isRestoringSettings, oldValue != isMuted else { return }
            if isMuted {
                volumeBeforeMute = volume
                volume = 0
            } else {
                volume = volumeBeforeMute
            }
        }
    }

    private var volumeBeforeMute: Double = 1.0 {
        didSet { settings.set(volumeBeforeMute, forKey: .volumeBeforeMute) }
    }

    /// True only while `restore(from:)` runs.
    ///
    /// Muting is a *derivation*: it moves the current level into
    /// `volumeBeforeMute` and drops `volume` to zero, so unmuting has
    /// somewhere to return to. That is right when the user hits the button
    /// and wrong on restore, where all three values were persisted and are
    /// authoritative — deriving there overwrote the saved `volumeBeforeMute`
    /// with the compiled-in default before `restore` could read it back, so
    /// launching muted and then unmuting jumped to full volume instead of the
    /// level you left. Suppressing the derivation fixes that without making
    /// the fix depend on the order the three assignments happen to run in.
    private var isRestoringSettings = false

    private func reshuffleAroundCurrent() {
        defer { persistQueue() }
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
    ///
    /// A prepared track that cannot be opened used to throw into a `try?` and
    /// vanish. Nothing was playing from it yet, so no event ever followed, and
    /// the failure surfaced minutes later as a stall at the transition instead
    /// of a skip now. It is recorded here and the track after it is offered
    /// instead, so the gap never arrives.
    private func prepareNextIfNeeded() {
        guard state.isActive else { return }
        var candidate = indexAfter(currentIndex)

        while let index = candidate, queue.indices.contains(index) {
            let track = queue[index]
            guard preparedNext != track.id else { return }
            do {
                try engine.prepareNext(url: track.url, duration: track.duration,
                                       gain: gain(for: track))
                // Only after the engine took it: a track it refused is not
                // prepared, and remembering it as such would suppress the
                // retry the next handshake would otherwise make.
                preparedNext = track.id
                return
            } catch {
                // Under Repeat One the candidate *is* the playing track. It
                // demonstrably opens, so a refusal to arm it again is the
                // engine's business, not a track to strike off the queue.
                guard index != currentIndex else { return }
                note(skip: track, reason: PlaybackError.diagnosing(error, at: track.url))
                candidate = indexAfter(index)
            }
        }
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
        // Every branch below changes something worth surviving a relaunch —
        // which track is current, or how far into it — so one `defer` covers
        // every exit rather than a call at the end of each case. See #42.
        defer { persistQueue() }
        switch event {
        case .started:
            if let track = currentTrack {
                state = .playing(track.id)
                progress.duration = track.duration
                onTrackStarted?(track)
            }
            if let position = pendingSeek {
                pendingSeek = nil
                seek(to: position)
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
                onTrackStarted?(track)
            }

        case .finished:
            if let index = indexAfter(currentIndex), index != currentIndex {
                start(at: index)
            } else if repeatMode == .one, let currentIndex {
                start(at: currentIndex)
            } else {
                stop()
            }

        case .outputDeviceLost:
            // Pause rather than carry on: audio suddenly leaving headphones for
            // the speakers is the behaviour every Mac user expects not to
            // happen. The position is kept so play resumes where it stopped.
            needsReloadAtPosition = progress.elapsed
            if let track = currentTrack { state = .paused(track.id) }
            notice = "Output device changed. Playback paused."
            noticeIsSticky = true

        case .failed(let error):
            // The engine gave up on this file. The record does not: a renamed
            // file, an unmounted NAS or one bad rip in the middle of an album
            // is the failure a filesystem-backed library actually meets, and
            // stopping on it leaves the user to work out which track did it.
            guard let index = currentIndex, queue.indices.contains(index) else {
                state = .failed(error)
                progress = .zero
                return
            }
            note(skip: queue[index],
                 reason: PlaybackError.diagnosing(error, at: queue[index].url))
            guard let next = indexAfter(index) else {
                stopAfterFailures()
                return
            }
            start(at: next)
        }
    }

    // MARK: - Persisting and restoring across launches

    /// Writes the queue, its pre-shuffle order, the current track and the
    /// position into it — everything `restoreQueue(resolving:)` needs to put
    /// it all back. `state` itself is deliberately not part of this: a
    /// relaunch always comes back paused, never mid-song. See #42.
    private func persistQueue() {
        settings.set(Self.encode(queue.map { $0.id.uuidString }), forKey: .queueTrackIDs)
        settings.set(Self.encode(orderedQueue.map { $0.id.uuidString }),
                     forKey: .queueOrderedTrackIDs)
        settings.set(currentTrack?.id.uuidString, forKey: .queueCurrentTrackID)
        settings.set(progress.elapsed, forKey: .queuePosition)
    }

    /// The position ticks ten times a second; writing it out on every tick
    /// would be ten `UserDefaults` writes a second for no benefit over one
    /// every few seconds. Every other change already goes through
    /// `persistQueue()` in full — this only exists so a crash mid-song loses
    /// at most a few seconds of position rather than all of it.
    private func persistPositionIfDue(_ time: TimeInterval) {
        let second = Int(time)
        guard second != lastPersistedPositionSecond, second % 5 == 0 else { return }
        lastPersistedPositionSecond = second
        settings.set(time, forKey: .queuePosition)
    }

    /// Flushes the exact position immediately. A normal quit fires no engine
    /// event for `persistQueue()` to ride along with, so the composition root
    /// calls this from `applicationWillTerminate` — otherwise the position
    /// restored next launch is only as fresh as the last five-second tick.
    public func flushQueueState() { persistQueue() }

    /// Puts the queue back the way it was at the last quit — paused at the
    /// right track, never playing, per #42. `PlaybackController` has no reach
    /// into the library (PLAN.md §5), so the composition root calls this once
    /// the library has loaded, resolving each persisted id to a real `Track`.
    ///
    /// An id that no longer resolves at all — a track removed from the
    /// library outright since last launch — is skipped over the same way the
    /// queue walks past a dead file during ordinary playback. A file that
    /// still has a library row but moved or vanished on disk is a different
    /// failure and surfaces later, from `start(at:)`, the moment the user
    /// presses Play — see #30.
    public func restoreQueue(resolving resolve: (Track.ID) -> Track?) {
        let queueIDs = pendingRestoreQueueIDs
        let orderedIDs = pendingRestoreOrderedQueueIDs
        let currentID = pendingRestoreCurrentTrackID
        let position = pendingRestorePosition
        pendingRestoreQueueIDs = []
        pendingRestoreOrderedQueueIDs = []
        pendingRestoreCurrentTrackID = nil
        pendingRestorePosition = 0

        // Nothing to restore onto, or something already queued in the
        // meantime — the latter shouldn't happen given when the composition
        // root calls this, but clobbering a queue already in progress would
        // be a worse failure than silently skipping the restore.
        guard queue.isEmpty else { return }
        let restoredQueue = queueIDs.compactMap(resolve)
        guard !restoredQueue.isEmpty else { return }

        let searchStart = currentID.flatMap { queueIDs.firstIndex(of: $0) } ?? 0
        guard let resumeID = queueIDs[searchStart...].first(where: { resolve($0) != nil }),
              let index = restoredQueue.firstIndex(where: { $0.id == resumeID })
        else { return }

        let restoredOrdered = orderedIDs.compactMap(resolve)
        queue = restoredQueue
        orderedQueue = restoredOrdered.isEmpty ? restoredQueue : restoredOrdered
        currentIndex = index
        let track = restoredQueue[index]
        // Only the track that was actually playing gets its position back;
        // one fallen through to starts at the top, the same rule
        // `start(at:)` already applies when a failure forces the same choice.
        let resumedAtOriginalPosition = resumeID == currentID
        state = .paused(track.id)
        progress = PlaybackProgress(
            elapsed: resumedAtOriginalPosition ? position : 0, duration: track.duration)
        // The engine has never been handed this track — `togglePlayPause`
        // reloads it at this position instead of calling `resume()` on a
        // graph that was never started, the same fallback `.outputDeviceLost`
        // already relies on.
        needsReloadAtPosition = resumedAtOriginalPosition ? position : 0
    }

    private static func encode(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        return (try? JSONEncoder().encode(values)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decode(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
