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
public actor RemoteTrackSource: TrackSource {

    private let downloader: any RemoteSongDownloading
    private let directory: URL
    private let budget: Int64
    private let protectedCount: Int

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

    /// - Parameters:
    ///   - directory: A folder of the cache's own, in the Caches directory.
    ///     The system may empty it when space runs short, which costs only a
    ///     second download.
    ///   - budget: Bytes the cache may hold before it removes files.
    ///   - protectedCount: How many of the most recently handed-out files
    ///     are never removed: the playing track, the next, and a margin.
    public init(downloader: any RemoteSongDownloading, directory: URL,
                budget: Int64 = 2_000_000_000, protectedCount: Int = 4) {
        self.downloader = downloader
        self.directory = directory
        self.budget = budget
        self.protectedCount = protectedCount
    }

    public func fileURL(for location: URL) async throws -> URL {
        guard let (songID, suffix) = RemoteTrackLocation.parse(location) else {
            throw PlaybackError.engine("This track is not in a shared library.")
        }
        let file = directory.appendingPathComponent(suffix.isEmpty ? songID : "\(songID).\(suffix)")

        if FileManager.default.fileExists(atPath: file.path) {
            hand(file)
            return file
        }

        let waiter = UUID()
        do {
            let url = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    wait(for: songID, file: file, as: waiter, continuation)
                }
            } onCancel: {
                Task { await self.abandon(songID, waiter) }
            }
            hand(url)
            return url
        } catch let error as RemoteError {
            throw PlaybackError.engine(error.message)
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
        // Runs on this actor, which it leaves while the download is awaited,
        // so bookkeeping at either end needs no hop.
        return Task {
            let partial = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await downloader.download(songID: songID, to: partial)
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
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
