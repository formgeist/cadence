import Testing
import Foundation
@testable import CadenceLibrary

@Suite("Artist images from the music folder", .enabled(if: FLACFixture.isAvailable))
struct FolderArtistImageTests {

    private struct Harness {
        var root: URL
        var music: URL
        var store: SQLiteLibraryStore
        var artwork: DiskArtworkStore
        var scanner: LibraryScanner

        func scan() async throws { try await scanner.scan(folder: music) }

        func folderImageBytes(for artist: String) async throws -> Data? {
            guard let id = try await store.folderArtistImages()[artist] else { return nil }
            return try await artwork.full(for: id)
        }
    }

    private static func makeHarness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-artist-image-\(UUID().uuidString)")
        let music = root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let store = try SQLiteLibraryStore(url: root.appendingPathComponent("db/library.sqlite"))
        let artwork = try DiskArtworkStore(root: root.appendingPathComponent("art"))
        let scanner = LibraryScanner(store: store, artwork: artwork)
        return Harness(root: root, music: music, store: store, artwork: artwork, scanner: scanner)
    }

    /// Two tracks by `artist` in `folder`.
    private static func album(_ title: String, by artist: String, in folder: URL) throws {
        try FLACFixture.build([
            .init(name: "01", tags: [("TITLE", "One"), ("ARTIST", artist),
                                     ("ALBUM", title), ("TRACKNUMBER", "1")]),
            .init(name: "02", tags: [("TITLE", "Two"), ("ARTIST", artist),
                                     ("ALBUM", title), ("TRACKNUMBER", "2")]),
        ], in: folder)
    }

    /// The same PNG with a trailing byte: still decodes, different hash.
    private static let otherPNG = FLACFixture.samplePNG + Data([0])

    @Test("An artist.jpg dropped in after the import is picked up by a plain rescan")
    func pickedUpWithoutForce() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let artistFolder = harness.music.appendingPathComponent("Band", isDirectory: true)
        try Self.album("First", by: "Band", in: artistFolder.appendingPathComponent("First"))
        // A disc subfolder: the picture two levels up still applies.
        try Self.album("Second", by: "Band",
                       in: artistFolder.appendingPathComponent("Second/CD1"))

        try await harness.scan()
        #expect(try await harness.store.folderArtistImages().isEmpty)

        try FLACFixture.samplePNG.write(to: artistFolder.appendingPathComponent("artist.jpg"))
        let summary = try await harness.scanner.scan(folder: harness.music)

        #expect(summary.imported == 0)
        #expect(try await harness.folderImageBytes(for: "Band") == FLACFixture.samplePNG)
    }

    @Test("Replacing or deleting artist.jpg is reflected on the next rescan")
    func followsChanges() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let artistFolder = harness.music.appendingPathComponent("Band", isDirectory: true)
        try Self.album("First", by: "Band", in: artistFolder.appendingPathComponent("First"))
        let image = artistFolder.appendingPathComponent("artist.jpg")

        try FLACFixture.samplePNG.write(to: image)
        try await harness.scan()
        #expect(try await harness.folderImageBytes(for: "Band") == FLACFixture.samplePNG)

        try Self.otherPNG.write(to: image)
        try await harness.scan()
        #expect(try await harness.folderImageBytes(for: "Band") == Self.otherPNG)

        try FileManager.default.removeItem(at: image)
        try await harness.scan()
        #expect(try await harness.store.folderArtistImages()["Band"] == nil)
    }

    @Test("A picture above several artists goes to nobody")
    func mixedFolderIsIgnored() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try Self.album("A", by: "Alpha", in: harness.music.appendingPathComponent("Alpha/A"))
        try Self.album("B", by: "Beta", in: harness.music.appendingPathComponent("Beta/B"))
        try FLACFixture.samplePNG.write(to: harness.music.appendingPathComponent("artist.jpg"))

        try await harness.scan()

        #expect(try await harness.store.folderArtistImages().isEmpty)
    }

    @Test("A file that does not decode as an image is ignored")
    func ignoresNonImages() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let artistFolder = harness.music.appendingPathComponent("Band", isDirectory: true)
        try Self.album("First", by: "Band", in: artistFolder.appendingPathComponent("First"))
        try Data("not an image".utf8).write(to: artistFolder.appendingPathComponent("artist.jpg"))

        try await harness.scan()

        #expect(try await harness.store.folderArtistImages().isEmpty)
    }

    @Test("Pruning keeps a folder image no track references")
    func survivesPrune() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let artistFolder = harness.music.appendingPathComponent("Band", isDirectory: true)
        try Self.album("First", by: "Band", in: artistFolder.appendingPathComponent("First"))
        try FLACFixture.samplePNG.write(to: artistFolder.appendingPathComponent("artist.jpg"))

        try await harness.scan()
        try await harness.scanner.pruneOrphanedArtwork()

        #expect(try await harness.folderImageBytes(for: "Band") == FLACFixture.samplePNG)
    }
}
