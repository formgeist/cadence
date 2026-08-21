import Foundation

/// Remembers the folders the user granted access to, and holds that access open.
///
/// Without app-scoped bookmarks the user's music folder becomes unreadable on
/// the second launch and there is no workaround — PLAN.md §5. The other half of
/// §7's warning is subtler: every `startAccessingSecurityScopedResource()` must
/// be paired with a stop, because leaking scoped resources eventually exhausts
/// the kernel's limit and file access starts failing in ways that look like
/// corruption. That pairing is why access is handed out as a token whose
/// lifetime ends the access, rather than as two calls a caller can forget to
/// balance.
///
/// Folders are bookmarked rather than individual files: access to a folder
/// extends to everything inside it, so one bookmark per imported folder covers
/// a whole library and keeps the number of open scopes to the number of folders.
public final class SecurityScopedFolders: @unchecked Sendable {

    /// Holds one folder's access open. Releasing it stops the access, so the
    /// pairing cannot be forgotten.
    public final class Access {
        public let url: URL
        private var isActive: Bool

        init(url: URL, isActive: Bool) {
            self.url = url
            self.isActive = isActive
        }

        /// Ends access early. Safe to call more than once.
        public func release() {
            guard isActive else { return }
            isActive = false
            url.stopAccessingSecurityScopedResource()
        }

        deinit { release() }
    }

    public struct Folder: Sendable, Equatable {
        public var url: URL
        public var bookmark: Data
        /// macOS asks for the bookmark to be remade — the folder moved, or the
        /// system decided the data is out of date.
        public var isStale: Bool
    }

    private let defaultsKey: String
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var accesses: [URL: Access] = [:]

    public init(defaultsKey: String = "CadenceFolderBookmarks",
                defaults: UserDefaults = .standard) {
        self.defaultsKey = defaultsKey
        self.defaults = defaults
    }

    deinit {
        for access in accesses.values { access.release() }
    }

    // MARK: - Making bookmarks

    /// Bookmarks a folder the user just chose and stores it.
    ///
    /// The bookmark is made from the URL exactly as given — that is the one the
    /// grant applies to — but it is *filed* under a normalised path. Resolving
    /// a bookmark hands back the canonical form (`/private/var/…` where the
    /// caller said `/var/…`), so without this the key and the resolved URL
    /// would disagree: `forget` would miss, and re-saving a stale bookmark
    /// would file a second copy of the same folder.
    @discardableResult
    public func remember(_ url: URL) throws -> Folder {
        let bookmark = try Self.makeBookmark(for: url)
        var stored = storedBookmarks()
        stored[Self.key(for: url)] = bookmark
        defaults.set(stored, forKey: defaultsKey)
        return Folder(url: url, bookmark: bookmark, isStale: false)
    }

    public func forget(_ url: URL) {
        var stored = storedBookmarks()
        stored[Self.key(for: url)] = nil
        defaults.set(stored, forKey: defaultsKey)
        lock.lock()
        for candidate in accesses.keys where Self.key(for: candidate) == Self.key(for: url) {
            accesses.removeValue(forKey: candidate)?.release()
        }
        lock.unlock()
    }

    /// One spelling per folder, whichever way the path was written.
    static func key(for url: URL) -> String {
        LibraryScanner.normalize(url).path
    }

    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    // MARK: - Resolving

    /// Resolves every stored bookmark and begins access. Stale bookmarks are
    /// re-made in place, which is what keeps a folder working after it has been
    /// moved or renamed.
    @discardableResult
    public func restoreAll() -> [Folder] {
        var resolved: [Folder] = []
        var stored = storedBookmarks()
        var changed = false

        for (path, bookmark) in stored {
            guard let folder = resolve(bookmark) else {
                // Unresolvable: the folder is gone. Dropping it beats retrying
                // on every launch forever.
                stored[path] = nil
                changed = true
                continue
            }
            beginAccess(to: folder.url)

            if folder.isStale, let remade = try? Self.makeBookmark(for: folder.url) {
                // Re-file under the same key, not the resolved spelling.
                stored[path] = nil
                stored[Self.key(for: folder.url)] = remade
                changed = true
                resolved.append(Folder(url: folder.url, bookmark: remade, isStale: false))
            } else {
                resolved.append(folder)
            }
        }

        if changed { defaults.set(stored, forKey: defaultsKey) }
        return resolved.sorted { $0.url.path < $1.url.path }
    }

    func resolve(_ bookmark: Data) -> Folder? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        else { return nil }
        return Folder(url: url, bookmark: bookmark, isStale: isStale)
    }

    // MARK: - Access

    /// Begins access if it is not already open. Idempotent, so callers can ask
    /// freely without counting.
    @discardableResult
    public func beginAccess(to url: URL) -> Access {
        lock.lock()
        defer { lock.unlock() }
        if let existing = accesses[url] { return existing }
        let started = url.startAccessingSecurityScopedResource()
        let access = Access(url: url, isActive: started)
        accesses[url] = access
        return access
    }

    /// The remembered folder containing `url`, if any — so a track can be
    /// played by first opening the scope its folder was granted under.
    public func folder(containing url: URL) -> URL? {
        lock.lock()
        let known = Array(accesses.keys)
        lock.unlock()
        return known.first { LibraryScanner.isDescendant(url, of: $0) }
    }

    public func releaseAll() {
        lock.lock()
        let all = accesses.values
        accesses.removeAll()
        lock.unlock()
        for access in all { access.release() }
    }

    public var rememberedPaths: [String] {
        storedBookmarks().keys.sorted()
    }

    private func storedBookmarks() -> [String: Data] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
