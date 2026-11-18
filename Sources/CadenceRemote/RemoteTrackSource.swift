import Foundation
import CadenceCore

/// Something that can fetch a song's file. `RemoteLibraryClient` in the app;
/// a stand-in in tests that need to count or hold downloads.
public protocol RemoteSongDownloading: Sendable {
    func download(songID: String, to destination: URL) async throws
}

extension RemoteLibraryClient: RemoteSongDownloading {}

/// The `TrackSource` for a library on a paired Mac: it downloads a track's
/// file into a cache folder and hands the engine that file.
///
/// Why whole files, and not a stream, is in `TrackSource`'s documentation.
///
/// - **One download per song.** An engine asks once to pre-buffer the next
///   track and again when it plays it. Both wait on the same download.
/// - **A skip stops the download**, once nothing else is waiting for it. A
///   cancelled caller gets `CancellationError` and nothing is left behind.
/// - **The cache has a budget.** Past it, the files used longest ago are
///   removed, never one being downloaded or one handed out recently, which
///   an engine may still have open.
/// - **Nothing half-written is ever handed out.** A download goes to a
///   partial file and is renamed into place only once it is complete.
/// - **A busy Mac is waited for, briefly.** The Mac allows each device a few
///   downloads at once and answers "busy" past that. A skip frees its slot
///   only once the Mac notices the dropped connection, so right after a few
///   quick skips the next download can be refused for a moment. That is
///   retried after the wait the Mac asks for, instead of failing the track
///   and skipping it. A long wait (the Mac refusing this address) is not.
/// - **A kept song is played from where it is kept.** With a
///   `RemoteDownloads` folder, `fileURL(for:)` looks there before the cache,
///   and `keep(_:)` puts a song there. Keeping shares downloads with
///   playback: a song being played and kept at once is downloaded once.
public actor RemoteTrackSource: TrackSource {

    private let downloader: any RemoteSongDownloading
    private let directory: URL
    private let downloads: RemoteDownloads?
    private let budget: Int64
    private let protectedCount: Int
    private let busyRetries: Int

    /// The longest wait a "busy" answer may ask for and still be retried.
    static let longestBusyWait: TimeInterval = 5

    private struct Pending {
        /// Tells this download apart from a later one for the same song.
        var token: UUID
        var task: Task<Void, Never>
        /// Each caller waiting, by its own id. A caller that is cancelled is
        /// answered at once and removed, without waiting for the download.
        var waiters: [UUID: CheckedContinuation<URL, any Error>]
    }
    private var pending: [String: Pending] = [:]
    /// The files handed out most recently, newest last.
    private var recent: [URL] = []
    /// Songs on their way from the cache into the kept folder, with how many
    /// `keep(_:)` calls are waiting on each. The budget never removes their
    /// cached file in between.
    private var keeping: [String: Int] = [:]

    /// - Parameters:
    ///   - directory: A folder of the cache's own, in the Caches directory.
    ///     The system may empty it when space runs short, which costs only a
    ///     second download.
    ///   - budget: Bytes the cache may hold before it removes files.
    ///   - protectedCount: How many of the most recently handed-out files
    ///     are never removed: the playing track, the next, and a margin.
    ///   - busyRetries: How many times a download the Mac answers "busy" is
    ///     tried again before the track fails.
    ///   - downloads: Where kept songs live, or nil for a source that only
    ///     caches. Required for `keep(_:)`.
    public init(downloader: any RemoteSongDownloading, directory: URL,
                budget: Int64 = 2_000_000_000, protectedCount: Int = 4,
                busyRetries: Int = 4, downloads: RemoteDownloads? = nil) {
        self.downloader = downloader
        self.directory = directory
        self.downloads = downloads
        self.budget = budget
        self.protectedCount = protectedCount
        self.busyRetries = busyRetries
    }

    public func fileURL(for location: URL) async throws -> URL {
        guard let (songID, suffix) = RemoteTrackLocation.parse(location) else {
            throw PlaybackError.engine("This track is not in a shared library.")
        }
        if let kept = downloads?.existingFile(songID: songID, suffix: suffix) {
            return kept
        }
        do {
            let file = try await cached(songID: songID, suffix: suffix)
            hand(file)
            return file
        } catch let error as RemoteError {
            throw PlaybackError.engine(error.message)
        }
    }

    // MARK: - Keeping

    /// Keeps a song on this device until it is removed from the
    /// `RemoteDownloads` folder, and returns its kept file.
    ///
    /// A song already in the cache is moved across without downloading it
    /// again, or copied when it was handed out recently and may be playing.
    /// A song being downloaded for playback is not downloaded twice. A song
    /// already kept is returned as it is.
    ///
    /// - Throws: `RemoteError` when the Mac cannot provide the song
    ///   (`.notFound` for a location that is not a remote track's), and
    ///   `CancellationError` when the caller is cancelled first. Either way
    ///   nothing is left in the kept folder.
    /// - Precondition: The source was created with a `downloads` folder.
    public func keep(_ location: URL) async throws -> URL {
        guard let downloads else {
            preconditionFailure("keep(_:) needs a RemoteTrackSource created with a downloads folder.")
        }
        guard let (songID, suffix) = RemoteTrackLocation.parse(location) else {
            throw RemoteError.notFound
        }
        if let kept = downloads.existingFile(songID: songID, suffix: suffix) {
            return kept
        }

        keeping[songID, default: 0] += 1
        defer {
            keeping[songID, default: 1] -= 1
            if keeping[songID] == 0 { keeping[songID] = nil }
        }
        let file = try await cached(songID: songID, suffix: suffix)
        // Another keep for the same song may have finished while this one
        // waited on the shared download.
        if let kept = downloads.existingFile(songID: songID, suffix: suffix) {
            return kept
        }
        let inUse = recent.contains { $0.standardizedFileURL == file.standardizedFileURL }
        do {
            return try downloads.keep(file, songID: songID, suffix: suffix, moving: !inUse)
        } catch {
            throw RemoteError.server(code: 0, message: error.localizedDescription)
        }
    }

    // MARK: - The cache

    /// The song's file in the cache, downloaded first if it is not there.
    /// Not handed out: the caller decides whether it counts as used.
    private func cached(songID: String, suffix: String) async throws -> URL {
        let file = directory.appendingPathComponent(suffix.isEmpty ? songID : "\(songID).\(suffix)")
        if FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait(for: songID, file: file, as: waiter, continuation)
            }
        } onCancel: {
            Task { await self.abandon(songID, waiter) }
        }
    }

    private func wait(for songID: String, file: URL, as waiter: UUID,
                      _ continuation: CheckedContinuation<URL, any Error>) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if pending[songID] == nil {
            let token = UUID()
            pending[songID] = Pending(
                token: token, task: start(songID: songID, file: file, token: token), waiters: [:])
        }
        pending[songID]?.waiters[waiter] = continuation
    }

    /// A caller stops waiting, and is answered now. When the last one gives
    /// up, the download is cancelled.
    private func abandon(_ songID: String, _ waiter: UUID) {
        guard var entry = pending[songID],
              let continuation = entry.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if entry.waiters.isEmpty {
            entry.task.cancel()
            pending[songID] = nil
        } else {
            pending[songID] = entry
        }
    }

    /// Removes every cached file. For when the device is unpaired.
    public func removeAll() {
        for entry in pending.values {
            entry.task.cancel()
            entry.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
        pending = [:]
        recent = []
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Downloads

    private func start(songID: String, file: URL, token: UUID) -> Task<Void, Never> {
        let downloader = downloader
        let directory = directory
        let busyRetries = busyRetries
        // Runs on this actor, which it leaves while the download is awaited,
        // so bookkeeping at either end needs no hop.
        return Task {
            let partial = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await Self.download(songID, to: partial, with: downloader, retries: busyRetries)
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: partial, to: file)
                self.finished(songID, token, .success(file))
            } catch {
                try? FileManager.default.removeItem(at: partial)
                self.finished(songID, token, .failure(error))
            }
        }
    }

    /// One download, tried again while the Mac says it is briefly busy.
    private static func download(_ songID: String, to partial: URL,
                                 with downloader: any RemoteSongDownloading,
                                 retries: Int) async throws {
        var left = retries
        while true {
            do {
                try await downloader.download(songID: songID, to: partial)
                return
            } catch RemoteError.busy(let wait) where left > 0 && wait <= longestBusyWait {
                left -= 1
                try? FileManager.default.removeItem(at: partial)
                try await Task.sleep(for: .seconds(max(wait, 0)))
            }
        }
    }

    /// Answers everyone still waiting for this download, unless it has
    /// already been abandoned and perhaps replaced by a later one.
    private func finished(_ songID: String, _ token: UUID, _ result: Result<URL, any Error>) {
        guard let entry = pending[songID], entry.token == token else { return }
        pending[songID] = nil
        if case .success(let file) = result { trim(keeping: file) }
        for continuation in entry.waiters.values { continuation.resume(with: result) }
    }

    // MARK: - Budget

    private func hand(_ file: URL) {
        recent.removeAll { $0 == file }
        recent.append(file)
        if recent.count > protectedCount { recent.removeFirst(recent.count - protectedCount) }
        // The modification date is the last use, so trimming removes the
        // file played longest ago, not the one downloaded longest ago.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    private func trim(keeping file: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int64, used: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > budget else { return }
        let kept = Set((recent + [file]).map(\.standardizedFileURL))
        entries.sort { $0.used < $1.used }
        for entry in entries where total > budget && !kept.contains(entry.url.standardizedFileURL) {
            // On its way into the kept folder: removing it now would fail
            // that keep after its download had already succeeded.
            let songID = String(entry.url.lastPathComponent.prefix { $0 != "." })
            if keeping[songID] != nil { continue }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
