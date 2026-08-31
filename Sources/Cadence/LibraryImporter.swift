import Foundation
import AppKit
import Observation
import CadenceCore
import CadenceLibrary

/// Owns the folder choice and the import that follows it.
///
/// Folders are remembered as app-scoped bookmarks, so access survives relaunch —
/// PLAN.md §5 is explicit that there is no workaround for getting this wrong.
/// `SecurityScopedFolders` holds the access open and pairs every start with a
/// stop.
@MainActor
@Observable
final class LibraryImporter {

    private(set) var progress: LibraryScanner.Progress?
    private(set) var lastSummary: LibraryScanner.Summary?
    private(set) var errorMessage: String?

    /// A passing word about the last scan, shown in the banner and dismissible.
    /// Only set when a scan couldn't read some files — the tracks it did import
    /// show up in the library itself, but a file skipped for being unreadable
    /// leaves no other trace. `errorMessage` is the separate channel for a scan
    /// that failed outright.
    private(set) var notice: String?

    func clearNotice() { notice = nil }

    var isImporting: Bool { progress != nil }

    /// The folders the user has added.
    private(set) var folders: [URL] = []

    /// Told when a folder is added or forgotten, so anything watching the
    /// filesystem for it — `FolderWatchCoordinator` — can start or stop in
    /// step. Set once by the composition root; this type stays otherwise
    /// ignorant of FSEvents, the same way it is already ignorant of
    /// `SecurityScopedFolders`'s internals.
    var onFolderAdded: ((URL) -> Void)?
    var onFolderForgotten: ((URL) -> Void)?

    private let scanner: LibraryScanner?
    private let bookmarks: SecurityScopedFolders
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    /// Folder path → when a scan of it last finished. Persisted so a relaunch
    /// a minute after the last one doesn't repeat a walk of every file that
    /// nothing has touched since.
    private var lastScanned: [String: Date]
    private static let lastScannedKey = "CadenceFolderLastScanned"
    /// How stale a folder's last scan has to be before a launch rescans it.
    /// Long enough that quitting and reopening the app doesn't repeat a walk
    /// that just ran; short enough that a folder is never silently out of
    /// date for more than a few minutes of continuous use.
    static let staleAfter: TimeInterval = 10 * 60

    init(scanner: LibraryScanner?, bookmarks: SecurityScopedFolders = SecurityScopedFolders(),
        defaults: UserDefaults = .standard) {
        self.scanner = scanner
        self.bookmarks = bookmarks
        self.defaults = defaults
        lastScanned = (defaults.dictionary(forKey: Self.lastScannedKey) as? [String: Date]) ?? [:]
        // Resolving on launch is what re-opens access to the music folder. A
        // folder that has moved gets its bookmark re-made rather than lost.
        folders = bookmarks.restoreAll().map(\.url)
    }

    // MARK: - Choosing

    /// Returns the chosen folder, or nil if the user cancelled.
    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add to Library"
        panel.message = "Choose a folder of FLAC files."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // The bookmark has to be made now, while the panel's grant is live.
        do {
            try bookmarks.remember(url)
            bookmarks.beginAccess(to: url)
        } catch {
            errorMessage = "Could not keep access to that folder: "
                + error.localizedDescription
            return nil
        }

        if !folders.contains(url) { folders.append(url) }
        onFolderAdded?(url)
        return url
    }

    func forget(_ url: URL) {
        folders.removeAll { $0 == url }
        bookmarks.forget(url)
        lastScanned[Self.scanKey(for: url)] = nil
        defaults.set(lastScanned, forKey: Self.lastScannedKey)
        onFolderForgotten?(url)
    }

    // MARK: - Importing

    /// Scans `folders` in turn. Completion runs after the library has been
    /// written, so the caller can reload from the store.
    ///
    /// `userInitiated` is off for the automatic scans — the launch catch-up and
    /// the folder watcher — so those stay silent about unreadable files rather
    /// than nagging about a condition the user didn't just ask to check.
    func importFolders(_ urls: [URL], force: Bool = false, userInitiated: Bool = true,
                       onFinish: @escaping @MainActor () -> Void) {
        guard let scanner, !urls.isEmpty, task == nil else { return }
        errorMessage = nil
        notice = nil
        progress = LibraryScanner.Progress()

        // Captured strongly on purpose: the importer must outlive the scan it
        // started, and it lives as long as the window anyway.
        task = Task {
            var combined = LibraryScanner.Summary()

            for url in urls {
                do {
                    let summary = try await scanner.scan(folder: url, force: force) { update in
                        Task { @MainActor in self.progress = update }
                    }
                    combined.imported += summary.imported
                    combined.skipped += summary.skipped
                    combined.failed += summary.failed
                    combined.removed += summary.removed
                    combined.failures += summary.failures
                    self.recordScanned(url)
                } catch is CancellationError {
                    break
                } catch {
                    self.errorMessage = error.localizedDescription
                    break
                }
            }

            // Best-effort and once per import rather than per folder: a
            // failed prune leaves stale files for next time, not a broken
            // library, so it must not turn a successful scan into an error.
            try? await scanner.pruneOrphanedArtwork()

            self.progress = nil
            self.lastSummary = combined
            self.notice = userInitiated ? Self.completionNotice(for: combined) : nil
            self.task = nil
            onFinish()
        }
    }

    /// The one thing a finished scan can't show on its own: the files it
    /// couldn't read. Their absence from the library looks the same as never
    /// having added them.
    private static func completionNotice(for summary: LibraryScanner.Summary) -> String? {
        guard summary.failed > 0 else { return nil }
        let files = summary.failed == 1 ? "1 file" : "\(summary.failed) files"
        guard summary.imported > 0 else { return "\(files) couldn’t be read" }
        let added = summary.imported == 1 ? "1 track" : "\(summary.imported) tracks"
        return "Added \(added) — \(files) couldn’t be read"
    }

    func rescanAll(onFinish: @escaping @MainActor () -> Void) {
        importFolders(folders, onFinish: onFinish)
    }

    /// What a launch rescans: every folder minus whatever was scanned
    /// recently enough — by this same launch's import, by ⌘R a moment ago,
    /// or by an earlier session — not to need walking again. Unlike
    /// `rescanAll`, which ⌘R uses to mean "scan everything, right now,"
    /// this is allowed to find nothing to do.
    func rescanStaleFolders(onFinish: @escaping @MainActor () -> Void) {
        let now = Date()
        let stale = folders.filter { url in
            guard let last = lastScanned[Self.scanKey(for: url)] else { return true }
            return now.timeIntervalSince(last) > Self.staleAfter
        }
        guard !stale.isEmpty else { return }
        importFolders(stale, userInitiated: false, onFinish: onFinish)
    }

    /// Re-reads every file, fingerprint or not. The way back from artwork that
    /// is no longer on disk: an ordinary rescan skips every unchanged file and
    /// so re-reads nothing, which is exactly the case that needs re-reading.
    func rescanAllForcingReread(onFinish: @escaping @MainActor () -> Void) {
        importFolders(folders, force: true, onFinish: onFinish)
    }

    /// Batches already committed stay committed, so a cancelled import is
    /// resumable rather than wasted.
    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    // MARK: - Scan recency

    private func recordScanned(_ url: URL) {
        lastScanned[Self.scanKey(for: url)] = Date()
        defaults.set(lastScanned, forKey: Self.lastScannedKey)
    }

    /// One spelling per folder, the same way `SecurityScopedFolders` files
    /// its bookmarks — otherwise a folder scanned via one path spelling and
    /// checked via another looks stale every time.
    private static func scanKey(for url: URL) -> String {
        LibraryScanner.normalize(url).path
    }
}
