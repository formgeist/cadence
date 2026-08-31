import Testing
import Foundation
@testable import CadenceLibrary

/// Bookmarks are the piece PLAN.md §5 says has no workaround if it is wrong,
/// and §7 warns about leaking scoped resources. Creating a real security-scoped
/// bookmark needs an actual user grant, so what is tested here is the
/// bookkeeping around it: storage, staleness, and — the part that bites — that
/// every start of access is paired with a stop.
@Suite("Security-scoped folders")
struct SecurityScopedFolderTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "cadence-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-bookmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A remembered folder is listed, and forgetting removes it")
    func rememberAndForget() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let folders = SecurityScopedFolders(defaultsKey: "bookmarks", defaults: defaults)
        try folders.remember(folder)
        #expect(folders.rememberedPaths == [SecurityScopedFolders.key(for: folder)])

        folders.forget(folder)
        #expect(folders.rememberedPaths.isEmpty)
    }

    @Test("Forgetting a folder ends its open access, not just its bookmark")
    func forgetReleasesAccess() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let folders = SecurityScopedFolders(defaultsKey: "bookmarks", defaults: defaults)
        try folders.remember(folder)
        let first = folders.beginAccess(to: folder)

        folders.forget(folder)

        // A live access is handed back on request; after forget the token is
        // gone, so the next request has to mint a fresh one. Same object back
        // would mean the scope from before forget is still open — the leak §7
        // is about.
        let second = folders.beginAccess(to: folder)
        #expect(first !== second)
        folders.releaseAll()
    }

    @Test("Bookmarks survive a new instance — this is what relaunch does")
    func survivesRelaunch() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = SecurityScopedFolders(defaultsKey: "bookmarks", defaults: defaults)
        try first.remember(folder)
        first.releaseAll()

        let second = SecurityScopedFolders(defaultsKey: "bookmarks", defaults: defaults)
        let restored = second.restoreAll()
        // Compared by normalised path: resolving a bookmark returns the
        // canonical spelling, which is not the one that went in.
        #expect(restored.map { SecurityScopedFolders.key(for: $0.url) }
                == [SecurityScopedFolders.key(for: folder)])
        second.releaseAll()
    }

    @Test("Forgetting works when the folder is named the other way round")
    func forgetMatchesAcrossSpellings() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let folders = SecurityScopedFolders(defaultsKey: "bookmarks", defaults: defaults)
        try folders.remember(folder)

        // The spelling a resolved bookmark would hand back.
        let canonical = URL(fileURLWithPath: "/private" + folder.path)
        let other = FileManager.default.fileExists(atPath: canonical.path) ? canonical : folder
        folders.forget(other)

        #expect(folders.rememberedPaths.isEmpty)
    }

    @Test("A bookmark whose folder is gone is dropped, not retried forever")
    func unresolvableBookmarkIsDropped() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["/nonexistent/folder": Data([0x00, 0x01, 0x02])], forKey: "bookmarks")
        let folders = SecurityScopedFolders(defaultsKey: "bookmarks", defaults: defaults)

        #expect(folders.restoreAll().isEmpty)
        #expect(folders.rememberedPaths.isEmpty)
    }

    @Test("Access is idempotent — asking twice yields one scope, not two")
    func accessIsIdempotent() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let folders = SecurityScopedFolders(defaultsKey: "bookmarks", defaults: defaults)
        let first = folders.beginAccess(to: folder)
        let second = folders.beginAccess(to: folder)
        // Two starts without two stops is exactly the leak §7 warns about.
        #expect(first === second)
        folders.releaseAll()
    }

    @Test("Releasing an access twice is safe")
    func doubleReleaseIsSafe() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let folders = SecurityScopedFolders(defaultsKey: "bookmarks", defaults: defaults)
        let access = folders.beginAccess(to: folder)
        access.release()
        access.release()
        folders.releaseAll()
    }

    @Test("A track is matched to the folder whose scope covers it")
    func findsCoveringFolder() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let folders = SecurityScopedFolders(defaultsKey: "bookmarks", defaults: defaults)
        folders.beginAccess(to: folder)

        let track = folder.appendingPathComponent("Album/01 Track.flac")
        #expect(folders.folder(containing: track) == folder)
        #expect(folders.folder(containing: URL(fileURLWithPath: "/elsewhere/x.flac")) == nil)
        folders.releaseAll()
    }
}
