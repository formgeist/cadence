import Testing
import Foundation
@testable import CadenceCore

@Suite("Similar artists and albums")
struct SimilarityTests {

    // MARK: Fixtures

    private func track(_ title: String, artist: String, albumArtist: String? = nil,
                       album: String, year: Int? = 2000, genre: String? = nil,
                       credits: [Credit] = [], compilation: Bool = false) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(albumArtist ?? artist)/\(album)/\(title).flac"),
              title: title, artist: artist, albumArtist: albumArtist, albumTitle: album,
              credits: credits, genre: genre, year: year, duration: 200,
              isCompilation: compilation)
    }

    private func album(_ title: String, by artist: String, year: Int? = 2000,
                       genre: String? = nil, credits: [Credit] = [],
                       trackArtists: [String]? = nil) -> Album {
        let artists = trackArtists ?? [artist]
        let tracks = artists.enumerated().map { i, trackArtist in
            track("\(title) \(i)", artist: trackArtist, albumArtist: artist, album: title,
                  year: year, genre: genre, credits: credits)
        }
        return Album(key: tracks[0].albumKey, tracks: tracks)
    }

    private func play(_ album: Album, at seconds: TimeInterval) -> PlayRecord {
        PlayRecord(track: album.tracks[0], playedAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: Artists

    @Test("A shared producer links two artists and names the producer")
    func sharedProducer() {
        let producer = [Credit(role: .producer, name: "Nigel Godrich")]
        let albums = [
            album("OK", by: "Radiohead", credits: producer),
            album("Sea Change", by: "Beck", credits: producer),
            album("Other", by: "Unrelated"),
        ]
        let index = SimilarityIndex(albums: albums, playlists: [], plays: [])
        let similar = index.artists(similarTo: "Radiohead")
        #expect(similar.map(\.name) == ["Beck"])
        #expect(similar.first?.reason == .sharedCredit(role: .producer, name: "Nigel Godrich"))
        #expect(similar.first?.reason.text == "Also produced by Nigel Godrich")
    }

    @Test("A credit on most of a large library is ignored as noise")
    func ubiquitousCredit() {
        let mastering = [Credit(role: .engineer, name: "Bob Ludwig")]
        let albums = (0..<30).map { album("A\($0)", by: "Artist \($0)", credits: mastering) }
        let index = SimilarityIndex(albums: albums, playlists: [], plays: [])
        #expect(index.artists(similarTo: "Artist 0").isEmpty)
    }

    @Test("A featured artist is a collaborator, matched across case and 'The'")
    func featureIsCollaboration() {
        let albums = [
            album("Host", by: "The Roots", trackArtists: ["The Roots", "the roots feat. Erykah Badu"]),
            album("Baduizm", by: "Erykah Badu"),
            album("Elsewhere", by: "Nobody"),
        ]
        let index = SimilarityIndex(albums: albums, playlists: [], plays: [])
        let fromRoots = index.artists(similarTo: "Roots")
        #expect(fromRoots.map(\.name) == ["Erykah Badu"])
        #expect(fromRoots.first?.reason == .collaboration)
        // The link runs both ways.
        #expect(index.artists(similarTo: "Erykah Badu").map(\.name) == ["The Roots"])
    }

    @Test("Playlists the listener made link the artists in them, counted")
    func playlistCooccurrence() {
        let a = album("A", by: "Alpha"), b = album("B", by: "Beta"), c = album("C", by: "Gamma")
        let playlists = [
            Playlist(name: "One", trackIDs: [a.tracks[0].id, b.tracks[0].id], duration: 0),
            Playlist(name: "Two", trackIDs: [a.tracks[0].id, b.tracks[0].id], duration: 0),
        ]
        let index = SimilarityIndex(albums: [a, b, c], playlists: playlists, plays: [])
        let similar = index.artists(similarTo: "Alpha")
        #expect(similar.map(\.name) == ["Beta"])
        #expect(similar.first?.reason == .playlists(2))
    }

    @Test("Plays in one sitting link artists; a long gap starts a new session")
    func listeningSessions() {
        let a = album("A", by: "Alpha"), b = album("B", by: "Beta"), c = album("C", by: "Gamma")
        let plays = [
            play(a, at: 0), play(b, at: 600),          // one session
            play(c, at: 600 + 3 * 60 * 60),           // hours later: its own
        ]
        let index = SimilarityIndex(albums: [a, b, c], playlists: [], plays: plays)
        let similar = index.artists(similarTo: "Alpha")
        #expect(similar.map(\.name) == ["Beta"])
        #expect(similar.first?.reason == .listenedTogether)
        #expect(index.artists(similarTo: "Gamma").isEmpty)
    }

    @Test("Genre alone fills the list, below anything with a real link")
    func genreIsWeakest() {
        let producer = [Credit(role: .producer, name: "Rick Rubin")]
        let albums = [
            album("A", by: "Alpha", genre: "Jazz", credits: producer),
            album("B", by: "Beta", genre: "Jazz"),
            album("C", by: "Gamma", genre: "Rock", credits: producer),
        ]
        let index = SimilarityIndex(albums: albums, playlists: [], plays: [])
        let similar = index.artists(similarTo: "Alpha")
        #expect(similar.map(\.name) == ["Gamma", "Beta"])
        #expect(similar.last?.reason == .genre("Jazz"))
    }

    @Test("Equal matches go to the artist the listener plays and owns more of")
    func tieBreakByListening() {
        let subject = album("S", by: "Subject", genre: "Rock")
        let aardvark = album("A", by: "Aardvark", genre: "Rock")
        let zebra = album("Z", by: "Zebra", genre: "Rock")
        let index = SimilarityIndex(albums: [subject, aardvark, zebra], playlists: [],
                                    plays: [play(zebra, at: 0)])
        #expect(index.artists(similarTo: "Subject").map(\.name) == ["Zebra", "Aardvark"])
    }

    @Test("Last.fm's list reaches library artists by folded name and wins the caption")
    func externalList() {
        let albums = [album("A", by: "Alpha"), album("B", by: "Björk")]
        let index = SimilarityIndex(albums: albums, playlists: [], plays: [])
        let external = [ExternalSimilarArtist(name: "bjork", match: 0.9),
                        ExternalSimilarArtist(name: "Not Here", match: 1)]
        let similar = index.artists(similarTo: "Alpha", external: external)
        #expect(similar.map(\.name) == ["Björk"])
        #expect(similar.first?.reason == .lastFM)
        #expect(index.libraryName(for: "Not Here") == nil)
    }

    @Test("Compilation artists count as weak collaborators, never as 'Various Artists'")
    func compilations() {
        let tracks = ["Alpha", "Beta"].map {
            track($0, artist: $0, albumArtist: "Various Artists", album: "Comp",
                  compilation: true)
        }
        let comp = Album(key: tracks[0].albumKey, tracks: tracks)
        let index = SimilarityIndex(
            albums: [comp, album("A", by: "Alpha"), album("B", by: "Beta")],
            playlists: [], plays: [])
        #expect(index.artists(similarTo: "Alpha").map(\.name) == ["Beta"])
        #expect(!index.contains(artist: "Various Artists"))
    }

    // MARK: Albums

    @Test("Similar albums skip the album's own artist and cap each other artist")
    func albumsExcludeOwnArtist() {
        let jazz = (0..<4).map { album("Beta \($0)", by: "Beta", year: 1960, genre: "Jazz") }
        let subject = album("Alpha 1", by: "Alpha", year: 1961, genre: "Jazz")
        let sibling = album("Alpha 2", by: "Alpha", year: 1962, genre: "Jazz")
        let index = SimilarityIndex(albums: [subject, sibling] + jazz, playlists: [], plays: [])
        let similar = index.albums(similarTo: subject.key, perArtist: 2)
        #expect(similar.count == 2)
        #expect(similar.allSatisfy { $0.key.albumArtist == "Beta" })
        #expect(similar.first?.reason == .genreAndEra("Jazz"))
    }

    @Test("An album inherits its artist's likeness and reason")
    func albumsFromSimilarArtists() {
        let subject = album("A", by: "Alpha")
        let other = album("B", by: "Beta")
        let index = SimilarityIndex(albums: [subject, other], playlists: [], plays: [])
        let artists = [SimilarArtist(name: "Beta", score: 1.2, reason: .lastFM)]
        let similar = index.albums(similarTo: subject.key, artists: artists)
        #expect(similar.map(\.key) == [other.key])
        #expect(similar.first?.reason == .lastFM)
    }

    @Test("A shared player on two albums links the albums themselves")
    func albumCredits() {
        let player = [Credit(role: .performer, name: "Ron Carter")]
        let a = album("A", by: "Alpha", credits: player)
        let b = album("B", by: "Beta", credits: player)
        let c = album("C", by: "Beta")
        let index = SimilarityIndex(albums: [a, b, c], playlists: [], plays: [])
        let similar = index.albums(similarTo: a.key)
        #expect(similar.map(\.key) == [b.key])
        #expect(similar.first?.reason.text == "Also features Ron Carter")
    }

    // MARK: Names

    @Test("Artist fields split on the usual separators, whole name first")
    func artistKeys() {
        #expect(Similarity.artistKeys(in: "A FEAT. B & C") == ["a feat. b & c", "a", "b", "c"])
        #expect(Similarity.artistKeys(in: "Simon & Garfunkel").first == "simon & garfunkel")
        #expect(Similarity.key(for: "  The Beatles ") == "beatles")
    }
}
