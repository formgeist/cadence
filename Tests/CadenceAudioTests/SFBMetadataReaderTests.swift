import Testing
import Foundation
@testable import CadenceAudio
import CadenceCore

/// The adapter's own translation layer. The decoding is SFB's problem; what is
/// tested here is the mapping into Cadence's model, which is where the bugs of
/// the "written against a remembered API" kind live — PLAN.md §3.
@Suite("SFB metadata translation")
struct SFBMetadataTranslationTests {

    @Test("Codec names SFB reports map onto ours", arguments: [
        ("FLAC", "flac", AudioFormat.Codec.flac),
        ("Apple Lossless", "m4a", .alac),
        ("MPEG-1 Layer III", "mp3", .mp3),
        ("Ogg Vorbis", "ogg", .vorbis),
        ("Ogg Opus", "opus", .opus),
        ("AIFF", "aiff", .aiff),
    ])
    func codecFromName(name: String, ext: String, expected: AudioFormat.Codec) {
        #expect(SFBMetadataReader.codec(name, extension: ext) == expected)
    }

    @Test("An unknown format name falls back to the extension", arguments: [
        ("m4a", AudioFormat.Codec.alac),
        ("mp3", .mp3),
        ("wav", .wav),
        ("flac", .flac),
    ])
    func codecFromExtension(ext: String, expected: AudioFormat.Codec) {
        #expect(SFBMetadataReader.codec(nil, extension: ext) == expected)
    }

    @Test("A format neither name nor extension identifies is kept, not discarded")
    func unknownCodecIsPreserved() {
        #expect(SFBMetadataReader.codec("Musepack", extension: "mpc")
                == .other("Musepack"))
    }

    @Test("Release dates arrive as free text", arguments: [
        ("1999", 1999), ("1999-08-15", 1999), ("1999/08/15", 1999),
        ("15 August 1999", 1999), ("", nil), ("not a date", nil),
    ])
    func releaseDates(raw: String, expected: Int?) {
        #expect(SFBMetadataReader.year(from: raw) == expected)
    }

    @Test("A four-digit run that is not a year is rejected")
    func implausibleYear() {
        #expect(SFBMetadataReader.year(from: "9999-01-01") == nil)
    }

    @Test("Whitespace is trimmed, and an empty tag reads as absent")
    func cleaning() {
        #expect(SFBMetadataReader.clean("  Korn ") == "Korn")
        #expect(SFBMetadataReader.clean("   ") == nil)
        #expect(SFBMetadataReader.clean(nil) == nil)
    }

    @Test("SFB claims the formats the library needs it for")
    func supportedExtensions() {
        let supported = SFBMetadataReader.supportedExtensions
        // The 611 ALAC files in a real library are the reason this reader
        // exists alongside the pure-Swift FLAC one.
        #expect(supported.contains("m4a"))
        #expect(supported.contains("mp3"))
        #expect(supported.contains("flac"))
    }
}

@Suite("Metadata routing")
struct MetadataRouterTests {

    private struct StubReader: MetadataReader {
        var name: String
        func readTrack(at url: URL) throws -> Track {
            Track(url: url, title: name, artist: name, albumTitle: name, duration: 1)
        }
        func readArtwork(at url: URL) throws -> Data? { nil }
    }

    @Test("Files go to the reader registered for their extension")
    func routesByExtension() throws {
        let router = MetadataRouter([
            "flac": StubReader(name: "flac-reader"),
            "m4a": StubReader(name: "sfb-reader"),
        ])
        let flac = try #require(router.reader(for: URL(fileURLWithPath: "/a.flac")))
        let alac = try #require(router.reader(for: URL(fileURLWithPath: "/a.m4a")))
        #expect(try flac.readTrack(at: URL(fileURLWithPath: "/a.flac")).title == "flac-reader")
        #expect(try alac.readTrack(at: URL(fileURLWithPath: "/a.m4a")).title == "sfb-reader")
    }

    @Test("Extensions are matched case-insensitively")
    func caseInsensitive() {
        let router = MetadataRouter(StubReader(name: "r"), extensions: ["flac"])
        #expect(router.reader(for: URL(fileURLWithPath: "/A.FLAC")) != nil)
    }

    @Test("An unregistered extension has no reader, rather than the wrong one")
    func unknownExtension() {
        let router = MetadataRouter(StubReader(name: "r"), extensions: ["flac"])
        #expect(router.reader(for: URL(fileURLWithPath: "/a.mp3")) == nil)
    }

    @Test("Merging layers a specialised reader over a general one")
    func merging() throws {
        // How the app composes it: SFB handles everything, then the dedicated
        // FLAC reader takes .flac back.
        let general = MetadataRouter(StubReader(name: "sfb"), extensions: ["flac", "m4a", "mp3"])
        let special = MetadataRouter(StubReader(name: "flac"), extensions: ["flac"])
        let merged = general.merging(special)

        let flac = try #require(merged.reader(for: URL(fileURLWithPath: "/a.flac")))
        let mp3 = try #require(merged.reader(for: URL(fileURLWithPath: "/a.mp3")))
        #expect(try flac.readTrack(at: URL(fileURLWithPath: "/a")).title == "flac")
        #expect(try mp3.readTrack(at: URL(fileURLWithPath: "/a")).title == "sfb")
        #expect(merged.supportedExtensions == ["flac", "m4a", "mp3"])
    }
}
