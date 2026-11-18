import Foundation

/// Keeps songs in order, a few at a time, for albums and playlists the
/// listener chose to download.
///
/// The queue only decides what to keep next. Keeping itself is a closure,
/// in the app `RemoteTrackSource.keep(_:)`, which shares downloads with
/// playback and puts the file in the `RemoteDownloads` folder.
///
/// - **Songs are queued per group**, an album or a playlist, named by the
///   caller. A song in two groups is downloaded once, and stays wanted until
///   both are cancelled.
/// - **A few at a time.** The Mac limits how many downloads a device may have
///   open, and playback must not wait behind a long queue.
/// - **A failure stays with its song.** The song is marked failed and the
///   rest of the queue goes on. `retry(_:)` puts it back.
/// - **Losing the Mac pauses the queue** instead of failing every song in
///   turn. A song that fails with `.offline` or `.unreachable` goes back to
///   the front, and the queue waits for `resume()`. So does everything
///   running when `pause()` is called.
///
/// State is published as a `Snapshot` to every `snapshots()` stream.
public actor RemoteDownloadQueue {

    public typealias Keep = @Sendable (URL) async throws -> URL

    public enum SongState: Sendable, Equatable {
        case queued
        case downloading
        case kept
        case failed(message: String)
    }

    public struct Snapshot: Sendable, Equatable {
        /// Every song the queue knows of. Kept songs stay until their last
        /// group is cancelled.
        public var songs: [String: SongState] = [:]
        /// The song ids of each group, in the order they were queued.
        public var groups: [String: [String]] = [:]
        /// True while the queue starts nothing: paused by the caller, or
        /// after losing the Mac.
        public var paused = false

        public init() {}

        /// How many of a group's songs are kept, of how many.
        public func progress(of group: String) -> (kept: Int, total: Int) {
            let ids = groups[group] ?? []
            return (ids.filter { songs[$0] == .kept }.count, ids.count)
        }

        /// True when no song of the group is still queued or downloading.
        public func isFinished(_ group: String) -> Bool {
            (groups[group] ?? []).allSatisfy {
                switch songs[$0] {
                case .queued, .downloading: false
                default: true
                }
            }
        }
    }

    private struct Entry {
        var location: URL
        var groups: Set<String>
        var state: SongState
    }

    private let keep: Keep
    private let concurrency: Int
    private var entries: [String: Entry] = [:]
    /// Queued song ids, next first.
    private var order: [String] = []
    private var groups: [String: [String]] = [:]
    /// Running keeps. The token tells a finished run from a later one of the
    /// same song.
    private var running: [String: (token: UUID, started: Int, task: Task<Void, Never>)] = [:]
    private var starts = 0
    private var paused: Bool
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    /// - Parameters:
    ///   - keep: Keeps one song and returns its file.
    ///   - concurrency: How many songs are kept at once.
    ///   - paused: Start paused, for a caller that resumes once the Mac is
    ///     connected.
    public init(concurrency: Int = 2, paused: Bool = false, keep: @escaping Keep) {
        self.keep = keep
        self.concurrency = max(1, concurrency)
        self.paused = paused
    }

    /// The current state, then every change.
    public func snapshots() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream()
        let id = UUID()
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    public var snapshot: Snapshot {
        var snapshot = Snapshot()
        snapshot.songs = entries.mapValues(\.state)
        snapshot.groups = groups
        snapshot.paused = paused
        return snapshot
    }

    // MARK: - Asking

    /// Queues a group's songs, after everything already queued. Songs the
    /// group already has are left as they are; a failed one is not retried.
    ///
    /// - Parameter locations: Each song's track location
    ///   (`RemoteTrackLocation.url(songID:suffix:)`). Anything else is
    ///   ignored.
    public func enqueue(group: String, locations: [URL]) {
        var ids = groups[group] ?? []
        for location in locations {
            guard let (songID, _) = RemoteTrackLocation.parse(location) else { continue }
            if !ids.contains(songID) { ids.append(songID) }
            if entries[songID] != nil {
                entries[songID]?.groups.insert(group)
            } else {
                entries[songID] = Entry(location: location, groups: [group], state: .queued)
                order.append(songID)
            }
        }
        groups[group] = ids
        changed()
    }

    /// Stops downloading a group. Its songs no other group wants are dropped
    /// from the queue, and stopped if they are downloading. Songs already kept
    /// stay kept: removing files is `RemoteDownloads`' job.
    public func cancel(group: String) {
        guard let ids = groups.removeValue(forKey: group) else { return }
        for id in ids {
            entries[id]?.groups.remove(group)
            if entries[id]?.groups.isEmpty == true { drop(id) }
        }
        changed()
    }

    /// Stops every group.
    public func cancelAll() {
        for id in Array(entries.keys) { drop(id) }
        groups = [:]
        changed()
    }

    /// Puts a failed song back at the end of the queue.
    public func retry(_ songID: String) {
        guard case .failed = entries[songID]?.state else { return }
        entries[songID]?.state = .queued
        order.append(songID)
        changed()
    }

    /// Puts every failed song of a group back, or of every group when nil.
    public func retryFailed(in group: String? = nil) {
        let ids = group.map { groups[$0] ?? [] } ?? Array(entries.keys).sorted()
        for id in ids { retry(id) }
    }

    /// Starts nothing more, and puts what is running back at the front of
    /// the queue.
    public func pause() {
        guard !paused else { return }
        stopRunning()
        changed()
    }

    public func resume() {
        guard paused else { return }
        paused = false
        changed()
    }

    // MARK: - Running

    /// Publishes the state and starts what may start.
    private func changed() {
        while !paused, running.count < concurrency, let id = order.first {
            order.removeFirst()
            guard let entry = entries[id], entry.state == .queued else { continue }
            start(id, entry.location)
        }
        let snapshot = snapshot
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    private func start(_ id: String, _ location: URL) {
        let token = UUID()
        let keep = keep
        entries[id]?.state = .downloading
        let task = Task {
            let result: Result<URL, any Error>
            do { result = .success(try await keep(location)) } catch { result = .failure(error) }
            self.finished(id, token, result)
        }
        starts += 1
        running[id] = (token, starts, task)
    }

    /// Pauses, and puts what is running back at the front of the queue in
    /// the order it started.
    private func stopRunning() {
        paused = true
        for (id, run) in running.sorted(by: { $0.value.started > $1.value.started }) {
            run.task.cancel()
            running[id] = nil
            requeueFirst(id)
        }
    }

    private func finished(_ id: String, _ token: UUID, _ result: Result<URL, any Error>) {
        // Cancelled, paused or replaced since: whoever did that has already
        // decided what becomes of the song.
        guard running[id]?.token == token else { return }
        running[id] = nil
        switch result {
        case .success:
            entries[id]?.state = .kept
        case .failure(let error as RemoteError) where error == .offline || error == .unreachable:
            // The Mac is gone: the other songs running would fail the same way.
            requeueFirst(id)
            stopRunning()
        case .failure(is CancellationError):
            requeueFirst(id)
        case .failure(let error as RemoteError):
            entries[id]?.state = .failed(message: error.message)
        case .failure(let error):
            entries[id]?.state = .failed(message: error.localizedDescription)
        }
        changed()
    }

    private func requeueFirst(_ id: String) {
        guard entries[id] != nil else { return }
        entries[id]?.state = .queued
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// Forgets a song, stopping it if it is downloading. A kept song's file
    /// is not touched.
    private func drop(_ id: String) {
        running.removeValue(forKey: id)?.task.cancel()
        order.removeAll { $0 == id }
        entries[id] = nil
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
