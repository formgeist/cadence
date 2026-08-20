import Foundation
import AppKit
import Observation
import CadenceCore
import CadenceLibrary

/// Owns the folder choice and the import that follows it.
///
/// Security-scoped bookmarks are what PLAN.md §5 requires, and `Track.bookmark`
/// exists for them — but they need the sandbox entitlement, which needs an app
/// bundle, which needs Xcode. Until then the folder is remembered as a plain
/// path. The storage is isolated here so switching to a bookmark is a change to
/// two methods.
@MainActor
@Observable
final class LibraryImporter {

    private(set) var progress: LibraryScanner.Progress?
    private(set) var lastSummary: LibraryScanner.Summary?
    private(set) var errorMessage: String?

    var isImporting: Bool { progress != nil }

    /// The folders the user has added.
    private(set) var folders: [URL]

    private let scanner: LibraryScanner?
    private var task: Task<Void, Never>?

    private static let foldersKey = "CadenceMusicFolders"

    init(scanner: LibraryScanner?) {
        self.scanner = scanner
        folders = (UserDefaults.standard.array(forKey: Self.foldersKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
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
        remember(url)
        return url
    }

    private func remember(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.foldersKey)
    }

    func forget(_ url: URL) {
        folders.removeAll { $0 == url }
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.foldersKey)
    }

    // MARK: - Importing

    /// Scans `folders` in turn. Completion runs after the library has been
    /// written, so the caller can reload from the store.
    func importFolders(_ urls: [URL], onFinish: @escaping @MainActor () -> Void) {
        guard let scanner, !urls.isEmpty, task == nil else { return }
        errorMessage = nil
        progress = LibraryScanner.Progress()

        // Captured strongly on purpose: the importer must outlive the scan it
        // started, and it lives as long as the window anyway.
        task = Task {
            var combined = LibraryScanner.Summary()

            for url in urls {
                do {
                    let summary = try await scanner.scan(folder: url) { update in
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

    /// Batches already committed stay committed, so a cancelled import is
    /// resumable rather than wasted.
    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }
}
