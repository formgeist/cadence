import Testing
import Foundation
@testable import CadenceLibrary

@Suite("Local artwork fallback")
struct LocalArtworkFinderTests {

    private static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-local-art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("An empty folder has no local artwork")
    func emptyFolder() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(LocalArtworkFinder.artwork(in: folder) == nil)
    }

    @Test("cover.jpg is found and its bytes are returned")
    func findsCover() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("front cover".utf8)
        try bytes.write(to: folder.appendingPathComponent("cover.jpg"))
        #expect(LocalArtworkFinder.artwork(in: folder) == bytes)
    }

    @Test("The match is case-insensitive on both name and extension")
    func caseInsensitive() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("front cover".utf8)
        try bytes.write(to: folder.appendingPathComponent("Cover.JPG"))
        #expect(LocalArtworkFinder.artwork(in: folder) == bytes)
    }

    @Test("cover beats folder, front, and album when more than one exists")
    func namePriority() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("cover".utf8).write(to: folder.appendingPathComponent("cover.png"))
        try Data("folder".utf8).write(to: folder.appendingPathComponent("folder.jpg"))
        try Data("front".utf8).write(to: folder.appendingPathComponent("front.jpg"))
        #expect(LocalArtworkFinder.artwork(in: folder) == Data("cover".utf8))
    }

    @Test("folder.png is used when no cover file exists")
    func fallsBackToFolder() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("front".utf8).write(to: folder.appendingPathComponent("front.png"))
        try Data("folder".utf8).write(to: folder.appendingPathComponent("folder.png"))
        #expect(LocalArtworkFinder.artwork(in: folder) == Data("folder".utf8))
    }

    @Test("Files with unrecognised names are ignored")
    func ignoresUnrelatedFiles() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("notes".utf8).write(to: folder.appendingPathComponent("liner-notes.txt"))
        try Data("scan".utf8).write(to: folder.appendingPathComponent("booklet-scan.jpg"))
        #expect(LocalArtworkFinder.artwork(in: folder) == nil)
    }

    @Test("A cover in a subfolder does not count for its parent")
    func doesNotRecurse() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disc2 = folder.appendingPathComponent("Disc 2", isDirectory: true)
        try FileManager.default.createDirectory(at: disc2, withIntermediateDirectories: true)
        try Data("disc2 cover".utf8).write(to: disc2.appendingPathComponent("cover.jpg"))
        #expect(LocalArtworkFinder.artwork(in: folder) == nil)
    }
}
