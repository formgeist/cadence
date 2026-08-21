import Testing
import Foundation
@testable import CadenceLibrary
import CadenceCore

/// Where the two halves of the artwork store live, and what happens to a store
/// written before they were split apart.
///
/// Thumbnails are derived and belong in Caches. Originals are not: for artwork
/// lifted out of a tag, the bytes on disk are the only copy the app holds, and
/// macOS may evict anything under `~/Library/Caches` without asking.
@Suite("Artwork store", .serialized)
struct ArtworkStoreTests {

    private static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-artwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Originals and thumbnails can sit under separate roots")
    func splitRootsBothWork() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let originals = folder.appendingPathComponent("support/originals")
        let thumbnails = folder.appendingPathComponent("caches/thumbnails")
        let store = try DiskArtworkStore(originals: originals, thumbnails: thumbnails)

        let bytes = Data("cover bytes".utf8)
        let id = try await store.store(bytes)

        #expect(try await store.full(for: id) == bytes)
        // Written where it was asked to be, not under one shared parent.
        #expect(FileManager.default.fileExists(
            atPath: originals.appendingPathComponent(id).path))
    }

    @Test("The default originals directory is not inside Caches")
    func defaultOriginalsAreNotCached() throws {
        let originals = try DiskArtworkStore.defaultOriginalsURL()
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)

        #expect(!originals.path.hasPrefix(caches.path))
        #expect(originals.path.contains("Application Support"))
        // Thumbnails still belong there — they are regenerable by definition.
        #expect(try DiskArtworkStore.defaultThumbnailsURL().path.hasPrefix(caches.path))
    }

    @Test("Originals left in the old cache root are moved, not orphaned")
    func migratesLegacyOriginals() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let legacy = folder.appendingPathComponent("caches/Artwork/originals")
        let destination = folder.appendingPathComponent("support/Artwork/originals")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: legacy.appendingPathComponent("aaa"))
        try Data("two".utf8).write(to: legacy.appendingPathComponent("bbb"))

        DiskArtworkStore.migrateOriginals(from: legacy, to: destination)

        #expect(try Data(contentsOf: destination.appendingPathComponent("aaa"))
                == Data("one".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("bbb"))
                == Data("two".utf8))
        // The emptied directory goes with them rather than lingering.
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("A migration that meets a file already moved keeps the destination")
    func migrationPrefersTheDestination() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let legacy = folder.appendingPathComponent("caches/originals")
        let destination = folder.appendingPathComponent("support/originals")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination,
                                                withIntermediateDirectories: true)
        // Content addressing means same name, same bytes — so this can only be
        // the same image, and either copy would do.
        try Data("cover".utf8).write(to: legacy.appendingPathComponent("aaa"))
        try Data("cover".utf8).write(to: destination.appendingPathComponent("aaa"))

        DiskArtworkStore.migrateOriginals(from: legacy, to: destination)

        #expect(try Data(contentsOf: destination.appendingPathComponent("aaa"))
                == Data("cover".utf8))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Nothing to migrate is not an error")
    func migrationWithNoLegacyStoreIsQuiet() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let destination = folder.appendingPathComponent("support/originals")
        DiskArtworkStore.migrateOriginals(
            from: folder.appendingPathComponent("nothing-here"), to: destination)

        // Not created speculatively: there was nothing to put in it.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Pruning walks both roots")
    func pruneClearsBothHalves() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let originals = folder.appendingPathComponent("support/originals")
        let thumbnails = folder.appendingPathComponent("caches/thumbnails")
        let store = try DiskArtworkStore(originals: originals, thumbnails: thumbnails)

        let kept = try await store.store(Data("kept".utf8))
        let dropped = try await store.store(Data("dropped".utf8))
        // A thumbnail the system has not evicted, cut from the dropped cover.
        try Data("thumb".utf8).write(
            to: thumbnails.appendingPathComponent("\(dropped)-64.png"))

        try await store.prune(keeping: [kept])

        #expect(try await store.full(for: kept) != nil)
        #expect(try await store.full(for: dropped) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: thumbnails.appendingPathComponent("\(dropped)-64.png").path))
    }
}
