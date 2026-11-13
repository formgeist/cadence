import Foundation
import CadenceCore

/// Imports a folder into the store.
///
/// Three things make this survive a real library, all from PLAN.md §1:
/// files whose size and mtime are unchanged are skipped without being opened;
/// parsing runs with bounded parallelism rather than one task per file; and
/// writes are batched into transactions instead of one per track.
public actor LibraryScanner {

    public struct Progress: Sendable, Equatable {
        public var found: Int
        public var processed: Int
        public var imported: Int
        public var skipped: Int
        public var failed: Int
        public var removed: Int
        /// Files recognised as moved so far — see `Summary.moved`.
        public var moved: Int
        public var currentFile: String?

        public var fraction: Double {
            found > 0 ? min(Double(processed) / Double(found), 1) : 0
        }

        public init(found: Int = 0, processed: Int = 0, imported: Int = 0,
                    skipped: Int = 0, failed: Int = 0, removed: Int = 0,
                    moved: Int = 0, currentFile: String? = nil) {
            self.found = found
            self.processed = processed
            self.imported = imported
            self.skipped = skipped
            self.failed = failed
            self.removed = removed
            self.moved = moved
            self.currentFile = currentFile
        }
    }

    public struct Summary: Sendable, Equatable {
        public var imported: Int
        public var skipped: Int
        public var failed: Int
        public var removed: Int
        /// Files found at a new path and recognised as ones the library
        /// already had. Counted in `imported` too, and not in `removed`.
        public var moved: Int
        public var failures: [ScanFailure]

        public init(imported: Int = 0, skipped: Int = 0, failed: Int = 0,
                    removed: Int = 0, moved: Int = 0, failures: [ScanFailure] = []) {
            self.imported = imported
            self.skipped = skipped
            self.failed = failed
            self.removed = removed
            self.moved = moved
            self.failures = failures
        }
    }

    /// One file the scan found but couldn't turn into a track. Kept with its
    /// full path and the reason so it can be listed — and revealed in Finder —
    /// long after the scan that produced it, not just counted in a banner.
    public struct ScanFailure: Sendable, Equatable, Codable {
        public var path: String
        public var reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }

        public var fileName: String { (path as NSString).lastPathComponent }

        /// The one-line form the CLI and logs use.
        public var line: String { "\(fileName): \(reason)" }
    }

    /// FLAC only, which is what `CadenceLibrary` can read on its own. The app
    /// layers SFB's formats on top.
    public static let flacOnly = MetadataRouter(FLACMetadataReader(), extensions: ["flac"])

    private let store: SQLiteLibraryStore
    private let artwork: DiskArtworkStore?
    private let router: MetadataRouter
    private let batchSize: Int
    private let parallelism: Int

    /// Folders already checked for a local cover this scan, so an album of
    /// twenty tracks reads `cover.jpg` once rather than once per track.
    private var localArtworkCache: [URL: Data?] = [:]

    public var supportedExtensions: Set<String> { router.supportedExtensions }

    public init(
        store: SQLiteLibraryStore,
        artwork: DiskArtworkStore? = nil,
        router: MetadataRouter = LibraryScanner.flacOnly,
        batchSize: Int = 200,
        parallelism: Int = max(2, ProcessInfo.processInfo.activeProcessorCount)
    ) {
        self.store = store
        self.artwork = artwork
        self.router = router
        self.batchSize = batchSize
        self.parallelism = parallelism
    }

    /// Scans `folder`, reporting progress as it goes. Cancelling the enclosing
    /// task stops it: already-committed batches stay, which is what makes a
    /// cancelled import resumable rather than wasted.
    ///
    /// `force` re-reads every file even when its size and mtime say nothing
    /// changed. The fingerprint skip is what makes a rescan cheap, but it also
    /// means a library that lost its artwork on disk can never get it back:
    /// no file changed, so nothing is re-read, and every `artworkID` keeps
    /// pointing at bytes that are gone. A full re-read is the way out of that,
    /// and the only one — which is why it is a mode rather than the default.
    @discardableResult
    public func scan(
        folder: URL,
        force: Bool = false,
        removingMissing: Bool = true,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Summary {

        // Normalise the root the same way the enumerator normalises what it
        // finds, or the two can never be compared. `resolvingSymlinksInPath`
        // rewrites /private/tmp to /tmp, so a caller passing either form must
        // end up at the same place.
        let root = Self.normalize(folder)
        // Local covers can change between scans (a user drops one in after the
        // fact), so nothing from a previous run should linger.
        localArtworkCache.removeAll()
        let files = Self.audioFiles(in: root, extensions: router.supportedExtensions)
        var progress = Progress(found: files.count, processed: 0, imported: 0,
                                skipped: 0, failed: 0, removed: 0, currentFile: nil)
        onProgress?(progress)

        let known = try await store.fingerprints()
        var failures: [ScanFailure] = []

        // Files the library knows under this folder that are no longer there.
        // Worked out before anything is read, because some of them have not
        // left: they moved, and a file found at a new path further down may be
        // one of these. Only forget files under the folder just scanned —
        // another watched folder being offline must not empty the library.
        var gone: Set<URL> = []
        if removingMissing {
            let onDisk = Set(files)
            gone = Set(known.keys.filter {
                Self.isDescendant($0, of: root) && !onDisk.contains($0)
            })
        }
        var moves = try await MoveMatcher(gone: gone, known: known, store: store)
        var pendingMoves: [(from: URL, to: URL)] = []
        var batch: [(track: Track, fileSize: Int64)] = []

        var index = 0
        while index < files.count {
            try Task.checkCancellation()

            let slice = Array(files[index..<min(index + parallelism, files.count)])
            index += slice.count

            // One group per slice caps concurrent file handles. Spawning a task
            // per file across a 30k-track library exhausts the descriptor
            // limit long before it exhausts the CPU.
            let results = await withTaskGroup(of: FileResult.self) { group in
                for url in slice {
                    let reader = self.router.reader(for: url)
                    let fingerprint = FLACMetadataReader.fingerprint(for: url)
                    let unchanged = !force && fingerprint != nil && known[url] == fingerprint
                    group.addTask {
                        var result = Self.process(url: url, unchanged: unchanged, reader: reader)
                        if case .parsed(let track, let size, nil) = result.outcome,
                           let local = await self.localArtwork(in: url.deletingLastPathComponent()) {
                            result = FileResult(url: url, outcome: .parsed(track, size, local))
                        }
                        return result
                    }
                }
                var collected: [FileResult] = []
                for await result in group { collected.append(result) }
                return collected
            }

            for result in results {
                progress.processed += 1
                progress.currentFile = result.url.lastPathComponent

                switch result.outcome {
                case .skipped:
                    progress.skipped += 1

                case .failed(let message):
                    progress.failed += 1
                    failures.append(ScanFailure(path: result.url.path, reason: message))

                case .parsed(var track, let size, let cover):
                    if let cover, let artwork {
                        track.artworkID = try? await artwork.store(cover)
                    }
                    // A file the library has not seen at this path, that is
                    // byte-for-byte one it has just lost from another: the
                    // same file, moved. Re-point the row instead of adding a
                    // new one, so the track keeps its id.
                    if known[result.url] == nil, let from = moves.claim(for: track) {
                        pendingMoves.append((from, result.url))
                        progress.moved += 1
                    }
                    batch.append((track, size))
                    progress.imported += 1
                }
            }

            if batch.count >= batchSize {
                // Moves first: the upsert finds a row by path, so the row has
                // to be at the new path before it runs.
                try await store.relocate(pendingMoves)
                pendingMoves.removeAll()
                try await store.upsert(batch)
                batch.removeAll(keepingCapacity: true)
            }
            onProgress?(progress)
        }

        if !batch.isEmpty {
            try await store.relocate(pendingMoves)
            try await store.upsert(batch)
        }

        // What is left of `gone` once the moved files have been claimed really
        // has left.
        let removed = gone.subtracting(moves.claimed)
        if !removed.isEmpty {
            try await store.remove(urls: Array(removed))
            progress.removed = removed.count
        }

        progress.currentFile = nil
        onProgress?(progress)

        return Summary(
            imported: progress.imported,
            skipped: progress.skipped,
            failed: progress.failed,
            removed: progress.removed,
            moved: progress.moved,
            failures: failures)
    }

    /// Deletes artwork on disk that no track references any more — a track
    /// removed, retagged, or its cover replaced all orphan the old bytes.
    /// Meant to run once after a whole import (every folder), not per folder:
    /// the set of referenced ids is already the full library either way, so
    /// scanning it more than once just repeats the same disk walk for nothing.
    public func pruneOrphanedArtwork() async throws {
        guard let artwork else { return }
        try await artwork.prune(keeping: try await store.referencedArtworkIDs())
    }

    // MARK: - Local cover fallback

    /// Looks up (and memoises) whether `folder` holds a cover image, for the
    /// tracks whose own tags carried no artwork.
    private func localArtwork(in folder: URL) -> Data? {
        if let cached = localArtworkCache[folder] { return cached }
        let data = LocalArtworkFinder.artwork(in: folder)
        localArtworkCache[folder] = data
        return data
    }

    // MARK: - Moved files

    /// Pairs a file found at a new path with the row of a file that has gone
    /// missing, when they are the same file.
    ///
    /// Without this a moved or renamed folder is a delete and an add: every
    /// track gets a new id, and the delete cascades through `playlistItem` and
    /// `likedTrack`, so reorganising a music folder silently empties playlists
    /// and Liked Songs. A paired client holding track ids loses them too.
    ///
    /// "The same file" is deliberately strict. The fingerprint (size and
    /// modification time, both of which a move within a volume preserves) has
    /// to match, and then so do the tags that say which track it is. A wrong
    /// match would put one track's likes and playlist places on another, which
    /// is worse than losing them, so anything short of all of it is treated as
    /// a new file.
    private struct MoveMatcher {
        private var candidates: [String: [Track]] = [:]
        private(set) var claimed: Set<URL> = []

        init(gone: Set<URL>, known: [URL: String], store: SQLiteLibraryStore) async throws {
            guard !gone.isEmpty else { return }
            for track in try await store.tracks(at: Array(gone)) {
                guard let fingerprint = known[track.url] else { continue }
                candidates[fingerprint, default: []].append(track)
            }
        }

        /// The old path of `track`, if it is a missing file turning up
        /// somewhere new. Each missing file can be claimed once.
        mutating func claim(for track: Track) -> URL? {
            guard let fingerprint = track.fingerprint,
                  let match = candidates[fingerprint]?.first(where: {
                      !claimed.contains($0.url) && Self.isSameRecording($0, track)
                  }) else { return nil }
            claimed.insert(match.url)
            return match.url
        }

        private static func isSameRecording(_ a: Track, _ b: Track) -> Bool {
            a.title == b.title
                && a.artist == b.artist
                && a.albumArtist == b.albumArtist
                && a.albumTitle == b.albumTitle
                && a.trackNumber == b.trackNumber
                && a.discNumber == b.discNumber
                && abs(a.duration - b.duration) < 0.01
        }
    }

    // MARK: - Per-file work

    private struct FileResult: Sendable {
        var url: URL
        var outcome: Outcome

        enum Outcome: Sendable {
            case parsed(Track, Int64, Data?)
            case skipped
            case failed(String)
        }
    }

    private static func process(
        url: URL, unchanged: Bool, reader: (any MetadataReader)?
    ) -> FileResult {
        guard !unchanged else { return FileResult(url: url, outcome: .skipped) }
        guard let reader else {
            return FileResult(url: url, outcome: .failed("no reader for .\(url.pathExtension)"))
        }
        do {
            let (track, artwork) = try reader.readTrackAndArtwork(at: url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
            return FileResult(url: url, outcome: .parsed(track, size, artwork))
        } catch let error as MetadataError {
            return FileResult(url: url, outcome: .failed(Self.describe(error)))
        } catch {
            return FileResult(url: url, outcome: .failed(error.localizedDescription))
        }
    }

    private static func describe(_ error: MetadataError) -> String {
        switch error {
        case .notFLAC: "not a FLAC file"
        case .truncated: "metadata is truncated"
        }
    }

    // MARK: - Paths

    /// One canonical form for every path the scanner compares: symlinks
    /// resolved, `..` removed.
    public static func normalize(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Containment by path component, not by string prefix. `/Music` is not a
    /// parent of `/Music Backup`, however much their paths look alike.
    public static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let child = normalize(url).pathComponents
        let parent = normalize(root).pathComponents
        guard child.count > parent.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }

    // MARK: - Enumeration

    /// Depth-first, skipping package directories and hidden files. Sorted so a
    /// scan is reproducible and progress moves in a sensible order.
    public static func audioFiles(
        in folder: URL, extensions: Set<String> = ["flac"]
    ) -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            found.append(normalize(url))
        }
        return found.sorted { $0.path < $1.path }
    }
}
