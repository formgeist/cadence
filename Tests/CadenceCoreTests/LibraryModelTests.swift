import Testing
import Foundation
@testable import CadenceCore

// MARK: - Identity

@Suite("Album identity")
struct AlbumIdentityTests {

    @Test("Title alone would merge every Greatest Hits; the artist keeps them apart")
    func sameTitleDifferentArtists() {
        let a = Album.Key(albumArtist: "Beacon Field", title: "Greatest Hits", year: 1999)
        let b = Album.Key(albumArtist: "Ansel Vaughn", title: "Greatest Hits", year: 1999)
        #expect(a != b)
    }

    @Test("A remaster is a different album from the original")
    func remasterIsDistinct() {
        let original = Album.Key(albumArtist: "Vera Lindqvist",
                                 title: "Sound of the Slow Hours", year: 2023)
        let remaster = Album.Key(albumArtist: "Vera Lindqvist",
                                 title: "Sound of the Slow Hours", year: 2025)
        #expect(original != remaster)
    }

    @Test("The preview library keeps the remaster separate")
    func previewRemasterDoesNotMerge() {
        let slowHours = PreviewData.tracks.filter { $0.albumTitle == "Sound of the Slow Hours" }
        let keys = Set(slowHours.map(\.albumKey))
        #expect(keys.count == 2)
    }
}

// MARK: - Album grouping

@Suite("Album grouping")
struct AlbumGroupingTests {

    @Test("A three-disc box set groups into three discs, in order")
    func boxSetGroupsByDisc() throws {
        let album = try #require(PreviewData.album("The Complete Aldeburgh Recordings"))
        #expect(album.hasMultipleDiscs)
        #expect(album.discCount == 3)
        #expect(album.discs.map(\.number) == [1, 2, 3])
    }

    @Test("A single-disc album yields one unnumbered group, so no header is drawn")
    func singleDiscHasNoDiscNumber() throws {
        let album = try #require(PreviewData.album("Sound of the Slow Hours"))
        #expect(!album.hasMultipleDiscs)
        #expect(album.discs.count == 1)
        #expect(album.discs[0].number == nil)
    }

    @Test("Tracks with no track number sort last rather than first")
    func untaggedTracksSortLast() {
        let tagged = Track(url: URL(fileURLWithPath: "/a.flac"), title: "Second",
                           artist: "X", albumTitle: "Y", trackNumber: 2, duration: 10)
        let untagged = Track(url: URL(fileURLWithPath: "/b.flac"), title: "Unknown",
                             artist: "X", albumTitle: "Y", trackNumber: nil, duration: 10)
        let sorted = [untagged, tagged].sorted(by: Track.inAlbumOrder)
        #expect(sorted.map(\.title) == ["Second", "Unknown"])
    }

    @Test("Differing track artists mark the album a compilation")
    func variousArtistsDetected() throws {
        let album = try #require(PreviewData.album("Nordic Ambient, Vol. 4"))
        #expect(album.isCompilation)
    }

    @Test("A single-artist album is not a compilation")
    func singleArtistIsNotCompilation() throws {
        let album = try #require(PreviewData.album("Northerly"))
        #expect(!album.isCompilation)
        #expect(!album.showsTrackArtists)
    }

    @Test("A deluxe edition mis-tagged as a compilation is not believed")
    func misTaggedCompilation() {
        // Real libraries are full of these: COMPILATION=1 on every track of a
        // deluxe edition by a single band.
        let tracks = (1...3).map { index in
            Track(url: URL(fileURLWithPath: "/m/\(index).flac"),
                  title: "T\(index)", artist: "Sleep Token",
                  albumArtist: "Sleep Token", albumTitle: "Take Me Back To Eden",
                  duration: 100, isCompilation: true)
        }
        let album = Album(key: tracks[0].albumKey, tracks: tracks)
        #expect(!album.isCompilation)
        #expect(!album.showsTrackArtists)
    }

    @Test("One guest feature shows an artist line without becoming a compilation")
    func guestFeature() {
        var tracks = (1...3).map { index in
            Track(url: URL(fileURLWithPath: "/m/\(index).flac"),
                  title: "T\(index)", artist: "blink-182",
                  albumArtist: "blink-182", albumTitle: "blink-182", duration: 100)
        }
        tracks[1].artist = "blink-182 feat. Robert Smith"
        let album = Album(key: tracks[0].albumKey, tracks: tracks)
        #expect(!album.isCompilation)
        // The feature still needs saying, on that row.
        #expect(album.showsTrackArtists)
    }

    @Test("Various Artists is a compilation whatever the tags say")
    func variousArtistsAlwaysCompilation() {
        let tracks = [
            Track(url: URL(fileURLWithPath: "/m/1.flac"), title: "A", artist: "X",
                  albumArtist: "Various Artists", albumTitle: "Comp", duration: 10),
            Track(url: URL(fileURLWithPath: "/m/2.flac"), title: "B", artist: "Y",
                  albumArtist: "Various Artists", albumTitle: "Comp", duration: 10),
        ]
        #expect(Album(key: tracks[0].albumKey, tracks: tracks).isCompilation)
    }

    @Test("The album badge reports the highest quality present, not the first")
    func dominantFormatPrefersHighest() throws {
        let album = try #require(PreviewData.album("Sound of the Slow Hours"))
        let format = try #require(album.dominantFormat)
        #expect(format.bitDepth == 24)
        #expect(format.sampleRate == 96_000)
    }
}

// MARK: - Row subtitles

@Suite("Track row subtitles")
struct RowSubtitleTests {

    @Test("A single-artist album suppresses the redundant artist line")
    func suppressedOnSingleArtistAlbum() {
        let track = Track(url: URL(fileURLWithPath: "/a.flac"), title: "Slow Hours",
                          artist: "Vera Lindqvist", albumArtist: "Vera Lindqvist",
                          albumTitle: "Sound of the Slow Hours", duration: 10)
        #expect(track.rowSubtitle(showingArtist: false) == nil)
    }

    @Test("A compilation shows the artist on every row")
    func shownOnCompilation() {
        let track = Track(url: URL(fileURLWithPath: "/a.flac"), title: "Hydrofoil",
                          artist: "Ansel Vaughn", albumArtist: "Various Artists",
                          albumTitle: "Nordic Ambient, Vol. 4", duration: 10)
        #expect(track.rowSubtitle(showingArtist: true) == "Ansel Vaughn")
    }

    @Test("Classical prefers the composer over the performer")
    func composerWins() {
        let track = Track(url: URL(fileURLWithPath: "/a.flac"), title: "Passacaglia",
                          artist: "Cyrille Marchand", albumTitle: "Aldeburgh",
                          composer: "Benjamin Britten", duration: 10)
        #expect(track.rowSubtitle(showingArtist: false) == "Benjamin Britten")
    }
}

// MARK: - Formatting

@Suite("Formatting")
struct FormattingTests {

    @Test("Clock times", arguments: [
        (0.0, "0:00"), (5.0, "0:05"), (338.0, "5:38"), (3552.0, "59:12"), (3_723.0, "1:02:03"),
    ])
    func clock(seconds: TimeInterval, expected: String) {
        #expect(DurationFormat.clock(seconds) == expected)
    }

    @Test("A 59-minute track stays in minutes rather than rolling to an hour")
    func longformStaysInMinutes() {
        #expect(DurationFormat.clock(3_552) == "59:12")
    }

    @Test("Nonsense durations do not render as NaN")
    func invalidDurations() {
        #expect(DurationFormat.clock(.nan) == "--:--")
        #expect(DurationFormat.clock(-1) == "--:--")
    }

    @Test("Remaining time carries its minus sign and never goes positive-negative")
    func remaining() {
        #expect(DurationFormat.remaining(146) == "-2:26")
        #expect(DurationFormat.remaining(-5) == "-0:00")
    }

    @Test("Approximate durations", arguments: [
        (2_520.0, "42 min"), (11_400.0, "3 hr 10 min"), (3_600.0, "1 hr"), (0.0, "0 min"),
    ])
    func approximate(seconds: TimeInterval, expected: String) {
        #expect(DurationFormat.approximate(seconds) == expected)
    }

    @Test("Sample rates drop trailing zeroes but keep the .1 of 44.1")
    func formatDescriptions() {
        #expect(AudioFormat.hiRes.shortDescription == "24/96")
        #expect(AudioFormat.cd.shortDescription == "16/44.1")
        #expect(AudioFormat.hiRes.longDescription == "24-bit / 96 kHz")
        #expect(AudioFormat.cd.badgeDescription == "FLAC · 16-bit / 44.1 kHz")
    }

    @Test("Lossy formats report no bit depth")
    func lossyHasNoBitDepth() {
        let mp3 = AudioFormat(codec: .mp3, sampleRate: 44_100)
        #expect(mp3.shortDescription == "44.1 kHz")
        #expect(!mp3.isLossless)
    }
}

// MARK: - Sorting

@Suite("Artist sorting")
struct ArtistSortingTests {

    @Test("A leading article is ignored, the way a record shop shelves it")
    func stripsArticles() {
        #expect(Artist.stripArticle("The Beatles") == "Beatles")
        #expect(Artist.stripArticle("An Ending") == "Ending")
        #expect(Artist.stripArticle("Theatre of Voices") == "Theatre of Voices")
    }
}

// MARK: - Progress

@Suite("Playback progress")
struct ProgressTests {

    @Test("A zero-length track reports zero rather than NaN")
    func zeroDuration() {
        #expect(PlaybackProgress(elapsed: 10, duration: 0).fraction == 0)
    }

    @Test("Fraction is clamped past the end")
    func clamped() {
        #expect(PlaybackProgress(elapsed: 500, duration: 100).fraction == 1)
    }

    @Test("Remaining never goes negative")
    func remainingFloors() {
        #expect(PlaybackProgress(elapsed: 500, duration: 100).remaining == 0)
    }
}
