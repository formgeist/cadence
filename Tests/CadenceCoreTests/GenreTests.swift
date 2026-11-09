import Testing
import Foundation
@testable import CadenceCore

@Suite("Genre grouping")
struct GenreTests {

    private func track(_ title: String, album: String, artist: String = "Artist",
                       genre: String?, art: String? = nil) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(album)-\(title).flac"),
              title: title, artist: artist, albumTitle: album, genre: genre,
              duration: 60, artworkID: art)
    }

    private func albums(_ tracks: [Track]) -> [Album] { Album.grouped(from: tracks) }

    @Test("Spelling and case variants of a tag are one genre, named for the commonest spelling")
    func foldsVariants() {
        let result = Genre.grouped(from: albums([
            track("1", album: "A", genre: "Rock"),
            track("1", album: "B", genre: "rock"),
            track("1", album: "C", genre: " Rock "),
        ]))
        #expect(result.genres.count == 1)
        #expect(result.genres[0].name == "Rock")
        #expect(result.genres[0].albumCount == 3)
    }

    @Test("Albums with no genre tag belong to no genre")
    func untaggedAlbumsAreSkipped() {
        let result = Genre.grouped(from: albums([
            track("1", album: "A", genre: nil),
            track("1", album: "B", genre: "  "),
            track("1", album: "C", genre: "Jazz"),
        ]))
        #expect(result.genres.map(\.name) == ["Jazz"])
        #expect(result.albumsByGenre["jazz"]?.map(\.title) == ["C"])
    }

    @Test("An album sits in the genre most of its tracks carry")
    func albumTakesMajorityGenre() {
        let album = albums([
            track("1", album: "A", genre: "Jazz"),
            track("2", album: "A", genre: "Jazz"),
            track("3", album: "A", genre: "Blues"),
        ])[0]
        #expect(album.genreKey == "jazz")
    }

    @Test("Genres run A–Z and total their albums and tracks")
    func sortedWithTotals() {
        let result = Genre.grouped(from: albums([
            track("1", album: "A", genre: "Pop"),
            track("2", album: "A", genre: "Pop"),
            track("1", album: "B", genre: "Ambient"),
        ]))
        #expect(result.genres.map(\.name) == ["Ambient", "Pop"])
        #expect(result.genres[1].trackCount == 2)
        #expect(result.genres[1].duration == 120)
    }

    @Test("A genre keeps up to four distinct covers")
    func coversAreDistinctAndCapped() {
        let tracks = (1...6).map { track("1", album: "Album \($0)", genre: "Rock",
                                         art: $0 <= 2 ? "same" : "art\($0)") }
        let genre = Genre.grouped(from: albums(tracks)).genres[0]
        #expect(genre.artworkIDs.count == 4)
        #expect(Set(genre.artworkIDs).count == 4)
    }
}
