import Testing
import Foundation
@testable import CadenceLibrary
import CadenceCore

/// The forgiving parsers. Metadata in the wild violates the spec constantly —
/// PLAN.md §7 says add to these rather than to the importer, and add a test
/// each time. This is that file.
@Suite("Forgiving tag parsers")
struct TagParserTests {

    @Test("TRACKNUMBER carrying a total", arguments: [
        ("3/12", 3, 12), ("3", 3, nil), ("03/12", 3, 12), ("", nil, nil), ("A", nil, nil),
    ])
    func splitIndex(raw: String, number: Int?, total: Int?) {
        let (parsed, parsedTotal) = FLACMetadataReader.splitIndex(raw)
        #expect(parsed == number)
        #expect(parsedTotal == total)
    }

    @Test("Dates in every shape a tagger writes", arguments: [
        ("1969", 1969), ("1969-08-15", 1969), ("1969/08/15", 1969),
        ("15-08-1969", nil), ("", nil), ("not a year", nil), ("69", nil),
    ])
    func year(raw: String, expected: Int?) {
        #expect(FLACMetadataReader.year(from: raw) == expected)
    }

    @Test("Gain tags carry their units", arguments: [
        ("-6.40 dB", -6.4), ("-6.40dB", -6.4), ("+2.5 dB", 2.5), ("0.998", 0.998),
    ])
    func decibels(raw: String, expected: Double) {
        let parsed = FLACMetadataReader.decibels(raw)
        #expect(parsed != nil)
        #expect(abs((parsed ?? 0) - expected) < 0.0001)
    }

    @Test("A gain tag that is not a number yields nothing rather than zero")
    func unparseableGain() {
        // Zero would silently mean "unity gain", which is a different claim
        // from "this file has no gain tag".
        #expect(FLACMetadataReader.decibels("unknown") == nil)
    }

    @Test("A disc suffix is dropped only when DISCNUMBER agrees", arguments: [
        ("Kid A (1)", 1, "Kid A"),
        ("Kid A (2)", 2, "Kid A"),
        ("Issues (1)", 1, "Issues"),
        // Disagrees with the tag, so it is part of the name.
        ("Untitled (2)", 1, "Untitled (2)"),
        // No disc tag at all: nothing to corroborate the guess.
        ("Kid A (1)", nil, "Kid A (1)"),
        // Not a disc index.
        ("Album (Deluxe)", 1, "Album (Deluxe)"),
        ("10,000 Days", 1, "10,000 Days"),
        ("( )", 1, "( )"),
    ])
    func discSuffix(raw: String, disc: Int?, expected: String) {
        #expect(FLACMetadataReader.albumTitle(raw, discNumber: disc) == expected)
    }

    @Test("Repeated keys are all kept")
    func repeatedKeys() {
        var comments = VorbisComments()
        comments.append(key: "ARTIST", value: "Vera Lindqvist")
        comments.append(key: "ARTIST", value: "Halvard Ås")
        #expect(comments.values(for: "ARTIST").count == 2)
        #expect(comments.value(for: "artist") == "Vera Lindqvist")
    }

    @Test("STREAMINFO with a zero sample rate does not divide by zero")
    func zeroSampleRate() {
        let info = FLACMetadataReader.parseStreamInfo(Data(repeating: 0, count: 34))
        #expect(info.duration == 0)
        #expect(info.sampleRate > 0)
    }

    @Test("A short STREAMINFO block falls back rather than reading past the end")
    func truncatedStreamInfo() {
        let info = FLACMetadataReader.parseStreamInfo(Data(repeating: 0, count: 4))
        #expect(info.sampleRate == 44_100)
    }
}

@Suite("Reading real FLAC files", .enabled(if: FLACFixture.isAvailable))
struct RealFileTests {

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A fully tagged file round-trips")
    func wellTaggedFile() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try FLACFixture.build([
            .init(name: "slow-hours", tags: [
                ("TITLE", "Slow Hours"),
                ("ARTIST", "Vera Lindqvist"),
                ("ALBUM", "Sound of the Slow Hours"),
                ("ALBUMARTIST", "Vera Lindqvist"),
                ("DATE", "2023-04-11"),
                ("TRACKNUMBER", "2/9"),
                ("DISCNUMBER", "1/1"),
                ("GENRE", "Ambient"),
                ("REPLAYGAIN_TRACK_GAIN", "-6.40 dB"),
                ("REPLAYGAIN_ALBUM_GAIN", "-6.10 dB"),
            ]),
        ], in: dir)

        let track = try FLACMetadataReader().readTrack(at: urls[0])

        #expect(track.title == "Slow Hours")
        #expect(track.artist == "Vera Lindqvist")
        #expect(track.albumTitle == "Sound of the Slow Hours")
        #expect(track.year == 2023)
        #expect(track.trackNumber == 2)
        #expect(track.trackCount == 9)
        #expect(track.genre == "Ambient")
        #expect(track.format.codec == .flac)
        #expect(track.format.sampleRate == 44_100)
        #expect(track.format.bitDepth == 16)
        #expect(track.duration > 0.3 && track.duration < 0.5)
        #expect(abs((track.replayGain?.trackGain ?? 0) + 6.4) < 0.001)
    }

    @Test("Hi-res files report their real rate and depth")
    func hiResFile() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try FLACFixture.build([
            .init(name: "hires", tags: [("TITLE", "Undertow")],
                  sampleRate: 96_000, bitDepth: 24),
        ], in: dir)

        let track = try FLACMetadataReader().readTrack(at: urls[0])
        #expect(track.format.sampleRate == 96_000)
        #expect(track.format.bitDepth == 24)
        #expect(track.format.shortDescription == "24/96")
    }

    @Test("An untagged file falls back to the filename rather than being skipped")
    func untaggedFile() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try FLACFixture.build([.init(name: "no-tags-here", tags: [])], in: dir)
        let track = try FLACMetadataReader().readTrack(at: urls[0])

        #expect(track.title == "no-tags-here")
        #expect(track.artist == "Unknown Artist")
        #expect(track.albumTitle == "Unknown Album")
        #expect(track.duration > 0)
    }

    @Test("Several ARTIST fields are joined, not silently dropped")
    func multipleArtists() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try FLACFixture.build([
            .init(name: "duet", tags: [
                ("TITLE", "Duet"),
                ("ARTIST", "Vera Lindqvist"),
                ("ARTIST", "Colm Bregha"),
            ]),
        ], in: dir)

        let track = try FLACMetadataReader().readTrack(at: urls[0])
        #expect(track.artist == "Vera Lindqvist, Colm Bregha")
    }

    @Test("A compilation with no ALBUMARTIST becomes Various Artists")
    func compilationWithoutAlbumArtist() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try FLACFixture.build([
            .init(name: "comp", tags: [
                ("TITLE", "Hydrofoil"),
                ("ARTIST", "Ansel Vaughn"),
                ("ALBUM", "Nordic Ambient, Vol. 4"),
                ("COMPILATION", "1"),
            ]),
        ], in: dir)

        let track = try FLACMetadataReader().readTrack(at: urls[0])
        #expect(track.isCompilation)
        #expect(track.albumArtist == "Various Artists")
        #expect(track.artist == "Ansel Vaughn")
    }

    @Test("Embedded cover art is found")
    func embeddedArtwork() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try FLACFixture.build([
            .init(name: "with-art", tags: [("TITLE", "Cover")],
                  picture: FLACFixture.samplePNG),
        ], in: dir)

        let artwork = try FLACMetadataReader().readArtwork(at: urls[0])
        #expect(artwork == FLACFixture.samplePNG)
    }

    @Test("A file with no PICTURE block reports no artwork rather than throwing")
    func noArtwork() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try FLACFixture.build([.init(name: "bare", tags: [])], in: dir)
        #expect(try FLACMetadataReader().readArtwork(at: urls[0]) == nil)
    }

    @Test("Something that isn't FLAC is rejected by name, not by crashing")
    func notFLAC() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("liar.flac")
        try Data("this is not a FLAC file, whatever the extension says".utf8).write(to: url)

        #expect(throws: MetadataError.notFLAC(url)) {
            try FLACMetadataReader().readTrack(at: url)
        }
    }

    @Test("A truncated file is reported, not read past the end of")
    func truncatedFile() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try FLACFixture.build([.init(name: "whole", tags: [("TITLE", "x")])], in: dir)
        let whole = try Data(contentsOf: urls[0])
        let cut = dir.appendingPathComponent("cut.flac")
        try whole.prefix(20).write(to: cut)

        #expect(throws: MetadataError.self) {
            try FLACMetadataReader().readTrack(at: cut)
        }
    }
}
