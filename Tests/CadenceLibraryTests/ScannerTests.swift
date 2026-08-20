import Testing
import Foundation
@testable import CadenceLibrary
import CadenceCore

/// PLAN.md §2 step 5: scan a fixture folder of real FLAC files and assert on
/// the resulting library. Everything downstream depends on import being
/// correct, so this is the test that matters most.
@Suite("Import", .enabled(if: FLACFixture.isAvailable), .serialized)
struct ScannerTests {

    /// A folder holding the awkward cases a real collection contains: a
    /// multi-disc set, a Various Artists compilation, classical tracks where
    /// the composer outranks the performer, hi-res alongside CD rate, embedded
    /// art on some files and none on others, and one file that is not FLAC at
    /// all.
    private static let corpus: [FLACFixture.Spec] = [
        // A straightforward album.
        .init(name: "01-morning-static", tags: [
            ("TITLE", "Morning Static"), ("ARTIST", "Vera Lindqvist"),
            ("ALBUM", "Sound of the Slow Hours"), ("ALBUMARTIST", "Vera Lindqvist"),
            ("DATE", "2023"), ("TRACKNUMBER", "1/2"), ("GENRE", "Ambient"),
            ("REPLAYGAIN_TRACK_GAIN", "-6.40 dB"),
        ], picture: FLACFixture.samplePNG),
        .init(name: "02-slow-hours", tags: [
            ("TITLE", "Slow Hours"), ("ARTIST", "Vera Lindqvist"),
            ("ALBUM", "Sound of the Slow Hours"), ("ALBUMARTIST", "Vera Lindqvist"),
            ("DATE", "2023"), ("TRACKNUMBER", "2/2"), ("GENRE", "Ambient"),
        ], sampleRate: 96_000, bitDepth: 24, picture: FLACFixture.samplePNG),

        // Same artist, same title, different year: must not merge.
        .init(name: "03-remaster", tags: [
            ("TITLE", "Morning Static"), ("ARTIST", "Vera Lindqvist"),
            ("ALBUM", "Sound of the Slow Hours"), ("ALBUMARTIST", "Vera Lindqvist"),
            ("DATE", "2025"), ("TRACKNUMBER", "1"),
        ]),

        // Three discs, composer-forward.
        .init(name: "04-overture-d1", tags: [
            ("TITLE", "Overture"), ("ARTIST", "Cyrille Marchand"),
            ("ALBUM", "The Complete Aldeburgh Recordings"),
            ("ALBUMARTIST", "Cyrille Marchand"), ("COMPOSER", "Benjamin Britten"),
            ("DATE", "1976-05-02"), ("TRACKNUMBER", "1/2"), ("DISCNUMBER", "1/3"),
        ]),
        .init(name: "05-aria-d2", tags: [
            ("TITLE", "Aria"), ("ARTIST", "Cyrille Marchand"),
            ("ALBUM", "The Complete Aldeburgh Recordings"),
            ("ALBUMARTIST", "Cyrille Marchand"), ("COMPOSER", "Benjamin Britten"),
            ("DATE", "1976-05-02"), ("TRACKNUMBER", "1/1"), ("DISCNUMBER", "2/3"),
        ]),
        .init(name: "06-coda-d3", tags: [
            ("TITLE", "Final Performance"), ("ARTIST", "Cyrille Marchand"),
            ("ALBUM", "The Complete Aldeburgh Recordings"),
            ("ALBUMARTIST", "Cyrille Marchand"), ("COMPOSER", "Benjamin Britten"),
            ("DATE", "1976-05-02"), ("TRACKNUMBER", "1/1"), ("DISCNUMBER", "3/3"),
        ]),

        // Various Artists, tagged only with COMPILATION.
        .init(name: "07-hydrofoil", tags: [
            ("TITLE", "Hydrofoil"), ("ARTIST", "Ansel Vaughn"),
            ("ALBUM", "Nordic Ambient, Vol. 4"), ("COMPILATION", "1"), ("DATE", "2024"),
            ("TRACKNUMBER", "1"),
        ]),
        .init(name: "08-glacier-mouth", tags: [
            ("TITLE", "Glacier Mouth"), ("ARTIST", "Delta Sleep Choir"),
            ("ALBUM", "Nordic Ambient, Vol. 4"), ("COMPILATION", "1"), ("DATE", "2024"),
            ("TRACKNUMBER", "2"),
        ]),

        // No tags at all.
        .init(name: "09-untagged", tags: []),
    ]

    private static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Harness {
        var root: URL
        var music: URL
        var store: SQLiteLibraryStore
        var artwork: DiskArtworkStore
        var scanner: LibraryScanner
    }

    private static func makeHarness() throws -> Harness {
        let root = try makeFolder()
        let music = root.appendingPathComponent("Music", isDirectory: true)
        try FLACFixture.build(corpus, in: music)

        // A file that is not FLAC, sitting in the middle of the folder. One bad
        // file must not abort the import of the other nine.
        try Data("nope".utf8).write(to: music.appendingPathComponent("10-broken.flac"))
        // And something that isn't audio at all.
        try Data("notes".utf8).write(to: music.appendingPathComponent("liner-notes.txt"))

        let store = try SQLiteLibraryStore(
            url: root.appendingPathComponent("db/library.sqlite"))
        let artwork = try DiskArtworkStore(root: root.appendingPathComponent("art"))
        let scanner = LibraryScanner(store: store, artwork: artwork, batchSize: 4)
        return Harness(root: root, music: music, store: store,
                       artwork: artwork, scanner: scanner)
    }

    // MARK: - The scan

    @Test("A folder of real FLAC files imports into the library it should")
    func importsCorpus() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let summary = try await harness.scanner.scan(folder: harness.music)

        #expect(summary.imported == Self.corpus.count)
        // The junk .flac is a failure; the .txt is not audio and is never
        // considered.
        #expect(summary.failed == 1)
        #expect(summary.failures.count == 1)
        #expect(summary.failures[0].contains("10-broken.flac"))

        let tracks = try await harness.store.allTracks()
        #expect(tracks.count == Self.corpus.count)
    }

    @Test("Albums group the way the identity rules say they should")
    func albumIdentity() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.scanner.scan(folder: harness.music)

        let albums = try await harness.store.albums()
        // Slow Hours 2023, Slow Hours 2025, Aldeburgh, Nordic Ambient, Unknown.
        #expect(albums.count == 5)

        let slowHours = albums.filter { $0.title == "Sound of the Slow Hours" }
        #expect(slowHours.count == 2)
        #expect(Set(slowHours.map(\.year)) == [2023, 2025])
        #expect(slowHours.first { $0.year == 2023 }?.trackCount == 2)
    }

    @Test("The box set keeps its three discs, in order")
    func discGrouping() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.scanner.scan(folder: harness.music)

        let album = try #require(try await harness.store.albums()
            .first { $0.title == "The Complete Aldeburgh Recordings" })
        #expect(album.hasMultipleDiscs)
        #expect(album.discCount == 3)
        #expect(album.discs.map(\.number) == [1, 2, 3])
        #expect(album.tracks.allSatisfy { $0.composer == "Benjamin Britten" })
        #expect(album.year == 1976)
    }

    @Test("The compilation is recognised without an ALBUMARTIST tag")
    func compilation() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.scanner.scan(folder: harness.music)

        let album = try #require(try await harness.store.albums()
            .first { $0.title == "Nordic Ambient, Vol. 4" })
        #expect(album.isCompilation)
        #expect(album.albumArtist == "Various Artists")
        #expect(Set(album.tracks.map(\.artist)) == ["Ansel Vaughn", "Delta Sleep Choir"])
    }

    @Test("Formats are read per file, not assumed for the album")
    func mixedFormats() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.scanner.scan(folder: harness.music)

        let album = try #require(try await harness.store.albums()
            .first { $0.title == "Sound of the Slow Hours" && $0.year == 2023 })
        #expect(Set(album.tracks.map(\.format.shortDescription)) == ["16/44.1", "24/96"])
        // The badge shows the best the record has to offer.
        #expect(album.dominantFormat?.shortDescription == "24/96")
    }

    @Test("Embedded artwork is extracted, stored once, and referenced")
    func artwork() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.scanner.scan(folder: harness.music)

        let withArt = try await harness.store.allTracks().filter { $0.artworkID != nil }
        #expect(withArt.count == 2)

        // Both files carry identical bytes, so content addressing must collapse
        // them to one entry.
        #expect(Set(withArt.map(\.artworkID)).count == 1)

        let id = try #require(withArt.first?.artworkID)
        #expect(try await harness.artwork.full(for: id) == FLACFixture.samplePNG)
        let thumbnail = try await harness.artwork.thumbnail(for: id, maxPixelSize: 64)
        #expect(thumbnail != nil)
    }

    @Test("Search works end to end, from files on disk to a query")
    func searchAfterImport() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.scanner.scan(folder: harness.music)

        #expect(try await harness.store.tracks(matching: "glacier").count == 1)
        #expect(try await harness.store.tracks(matching: "britten").count == 3)
        #expect(try await harness.store.tracks(matching: "aldeb").count == 3)
    }

    @Test("Library size reflects the files actually on disk")
    func librarySize() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.scanner.scan(folder: harness.music)
        #expect(try await harness.store.librarySize() > 0)
    }

    // MARK: - Rescanning

    @Test("A second scan skips every unchanged file")
    func rescanSkipsUnchanged() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        try await harness.scanner.scan(folder: harness.music)
        let second = try await harness.scanner.scan(folder: harness.music)

        #expect(second.imported == 0)
        #expect(second.skipped == Self.corpus.count)
        #expect(try await harness.store.allTracks().count == Self.corpus.count)
    }

    @Test("A retagged file is re-read on the next scan")
    func rescanPicksUpChanges() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.scanner.scan(folder: harness.music)

        try FLACFixture.build([
            .init(name: "01-morning-static", tags: [
                ("TITLE", "Morning Static (Alternate Take)"),
                ("ARTIST", "Vera Lindqvist"),
                ("ALBUM", "Sound of the Slow Hours"),
                ("ALBUMARTIST", "Vera Lindqvist"), ("DATE", "2023"),
                ("TRACKNUMBER", "1/2"),
            ]),
        ], in: harness.music)

        let second = try await harness.scanner.scan(folder: harness.music)
        #expect(second.imported == 1)

        let titles = try await harness.store.allTracks().map(\.title)
        #expect(titles.contains("Morning Static (Alternate Take)"))
        #expect(try await harness.store.allTracks().count == Self.corpus.count)
        #expect(try await harness.store.tracks(matching: "alternate").count == 1)
    }

    @Test("A deleted file leaves the library on the next scan")
    func rescanRemovesDeleted() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.scanner.scan(folder: harness.music)

        try FileManager.default.removeItem(
            at: harness.music.appendingPathComponent("08-glacier-mouth.flac"))

        let second = try await harness.scanner.scan(folder: harness.music)
        #expect(second.removed == 1)
        #expect(try await harness.store.allTracks().count == Self.corpus.count - 1)
        #expect(try await harness.store.tracks(matching: "glacier").isEmpty)
    }

    @Test("A folder named by an unresolved path still tracks deletions")
    func deletionSurvivesPathAliasing() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // The same folder, named the way a user or an NSOpenPanel might name
        // it rather than the way the enumerator canonicalises it.
        // `resolvingSymlinksInPath` rewrites /private/tmp to /tmp, so these two
        // spellings must not be treated as different folders.
        let aliased = URL(fileURLWithPath: "/private" + harness.music.path)
        let usable = FileManager.default.fileExists(atPath: aliased.path)
            ? aliased
            : harness.music

        try await harness.scanner.scan(folder: usable)
        #expect(try await harness.store.allTracks().count == Self.corpus.count)

        try FileManager.default.removeItem(
            at: harness.music.appendingPathComponent("08-glacier-mouth.flac"))

        let second = try await harness.scanner.scan(folder: usable)
        #expect(second.removed == 1)
        #expect(try await harness.store.allTracks().count == Self.corpus.count - 1)
    }

    @Test("A sibling folder sharing a name prefix is not swept up")
    func siblingPrefixIsNotADescendant() throws {
        let music = URL(fileURLWithPath: "/Users/x/Music")
        #expect(LibraryScanner.isDescendant(
            URL(fileURLWithPath: "/Users/x/Music/a.flac"), of: music))
        // The bug this guards: "/Users/x/Music Backup" starts with
        // "/Users/x/Music" as a string, but is a different folder.
        #expect(!LibraryScanner.isDescendant(
            URL(fileURLWithPath: "/Users/x/Music Backup/a.flac"), of: music))
        #expect(!LibraryScanner.isDescendant(music, of: music))
    }

    @Test("Progress reaches every file and ends complete")
    func progressReporting() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let updates = Updates()
        try await harness.scanner.scan(folder: harness.music) { progress in
            updates.append(progress)
        }

        let all = updates.values
        #expect(all.count > 1)
        #expect(all.last?.processed == Self.corpus.count + 1)   // + the junk file
        #expect(all.last?.fraction == 1)
        #expect(all.last?.currentFile == nil)
        // Progress only ever moves forward.
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.processed <= $1.processed })
    }

    @Test("Batched writes commit everything, including a final partial batch")
    func batchingCommitsAll() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // 9 tracks with a batch size of 4: two full batches and a remainder
        // that is only written by the flush after the loop.
        try await harness.scanner.scan(folder: harness.music)
        #expect(try await harness.store.allTracks().count == 9)
    }
}

/// Progress arrives on whatever task finished a slice, so collection needs a
/// lock rather than a plain array.
private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LibraryScanner.Progress] = []

    func append(_ progress: LibraryScanner.Progress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    var values: [LibraryScanner.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
