import Foundation
import CadenceLibrary

/// Arms every granted folder for automatic rescan and disarms it when the
/// folder is forgotten — PLAN.md §6.
///
/// A burst of FSEvents (a large copy, a tag editor rewriting an album) is
/// debounced per folder — cancel-and-restart a `Task`, the idiom
/// `AppModel.scheduleSearch()` already uses — so it collapses to one
/// `importer.importFolders` call after things go quiet, not one per event.
///
/// Rescans go through `LibraryImporter.importFolders(_:onFinish:)` rather than
/// the scanner directly, which gets progress tracking, `lastScanned`
/// bookkeeping, error surfacing, and the existing single-in-flight-task guard
/// for free — a watcher-triggered scan can never race a manual ⌘R. If a scan
/// is already running when a debounce fires, the trigger is silently dropped;
/// either another FSEvents callback arrives for that folder later, or the
/// next launch's `rescanStaleFolders` catches it up.
@MainActor
final class FolderWatchCoordinator {
    private let importer: LibraryImporter
    private let bookmarks: SecurityScopedFolders
    private let defaults: UserDefaults

    private var streams: [String: FolderEventStream] = [:]
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var pendingEventIDs: [String: FolderEventStream.EventID] = [:]
    private var lastEventIDs: [String: FolderEventStream.EventID]

    private static let lastEventIDKey = "CadenceFolderEventIDs"
    private static let debounceDelay: Duration = .seconds(2)

    init(importer: LibraryImporter, bookmarks: SecurityScopedFolders,
         defaults: UserDefaults = .standard) {
        self.importer = importer
        self.bookmarks = bookmarks
        self.defaults = defaults
        lastEventIDs = (defaults.dictionary(forKey: Self.lastEventIDKey)
            as? [String: FolderEventStream.EventID]) ?? [:]
        for url in importer.folders { startWatching(url) }
    }

    deinit {
        for task in debounceTasks.values { task.cancel() }
    }

    func folderAdded(_ url: URL) { startWatching(url) }

    func folderRemoved(_ url: URL) {
        let key = Self.key(for: url)
        streams[key]?.stop()
        streams[key] = nil
        debounceTasks[key]?.cancel()
        debounceTasks[key] = nil
        pendingEventIDs[key] = nil
        lastEventIDs[key] = nil
        defaults.set(lastEventIDs, forKey: Self.lastEventIDKey)
    }

    private func startWatching(_ url: URL) {
        let key = Self.key(for: url)
        guard streams[key] == nil else { return }
        // Idempotent — a no-op if restoreAll()/chooseFolder() already opened
        // it. Never released here; teardown only ever happens through
        // SecurityScopedFolders.forget/releaseAll/deinit, exactly as
        // LibraryImporter.chooseFolder() already relies on.
        bookmarks.beginAccess(to: url)

        streams[key] = FolderEventStream(url: url, since: lastEventIDs[key]) { [weak self] eventID in
            self?.scheduleRescan(key: key, url: url, eventID: eventID)
        }
    }

    private func scheduleRescan(key: String, url: URL, eventID: FolderEventStream.EventID) {
        pendingEventIDs[key] = eventID
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            self?.rescan(key: key, url: url)
        }
    }

    private func rescan(key: String, url: URL) {
        let eventID = pendingEventIDs[key]
        importer.importFolders([url], userInitiated: false) { [weak self] in
            guard let self, let eventID else { return }
            self.lastEventIDs[key] = eventID
            self.defaults.set(self.lastEventIDs, forKey: Self.lastEventIDKey)
        }
    }

    private static func key(for url: URL) -> String { LibraryScanner.normalize(url).path }
}
