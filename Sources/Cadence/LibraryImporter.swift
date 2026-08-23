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

    var isImporting: Bool { progress != nil }

    /// The folders the user has added.
    private(set) var folders: [URL] = []

    private let scanner: LibraryScanner?
    private let bookmarks: SecurityScopedFolders
    private var task: Task<Void, Never>?

    init(scanner: LibraryScanner?, bookmarks: SecurityScopedFolders = SecurityScopedFolders()) {
        self.scanner = scanner
        self.bookmarks = bookmarks
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
        return url
    }

    func forget(_ url: URL) {
        folders.removeAll { $0 == url }
        bookmarks.forget(url)
    }

    // MARK: - Importing

    /// Scans `folders` in turn. Completion runs after the library has been
    /// written, so the caller can reload from the store.
    func importFolders(_ urls: [URL], force: Bool = false,
                       onFinish: @escaping @MainActor () -> Void) {
        guard let scanner, !urls.isEmpty, task == nil else { return }
        errorMessage = nil
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
                } catch is CancellationError {
                    break
                } catch {
                    self.errorMessage = error.localizedDescription
                    break
                }
            }

            self.progress = nil
            self.lastSummary = combined
            self.task = nil
            onFinish()
        }
    }

    func rescanAll(onFinish: @escaping @MainActor () -> Void) {
        importFolders(folders, onFinish: onFinish)
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
}
