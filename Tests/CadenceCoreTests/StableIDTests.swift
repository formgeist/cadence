import Testing
import Foundation
import CadenceCore

@Suite("Stable ids")
struct StableIDTests {

    private let key = Album.Key(albumArtist: "Vera Lindqvist",
                                title: "Sound of the Slow Hours", year: 2023)

    /// The derivation is a wire format: paired clients and the identity tables
    /// hold these exact strings. If this test fails, the change that broke it
    /// orphans every id already issued.
    @Test("The derivation is pinned")
    func pinned() {
        #expect(StableID.album(key) == "al-" + Self.expectedAlbumDigest)
        #expect(StableID.artist(named: "Vera Lindqvist") == "ar-" + Self.expectedArtistDigest)
    }

    static let expectedAlbumDigest = "ff2aad72768cad7afd88c92657984e3f"
    static let expectedArtistDigest = "80d92ac50ec4be27593c7cfbe3d5891f"

    @Test("An id is a prefix and 32 hex characters, whatever the names hold")
    func shape() {
        let awkward = Album.Key(albumArtist: "AC/DC", title: "../../etc/passwd?id=1&x=\u{0}",
                                year: nil)
        for id in [StableID.album(awkward), StableID.artist(named: "Sigur Rós / 坂本龍一")] {
            let digest = id.dropFirst(3)
            #expect(id.hasPrefix("al-") || id.hasPrefix("ar-"))
            #expect(digest.count == 32)
            #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    @Test("Each part of an album's identity changes its id")
    func sensitivity() {
        var other = key
        other.year = 2024
        #expect(StableID.album(other) != StableID.album(key))
        other = key
        other.year = nil
        #expect(StableID.album(other) != StableID.album(key))
        other = key
        other.title = "Sound of the Slow Hours (Deluxe)"
        #expect(StableID.album(other) != StableID.album(key))
        other = key
        other.albumArtist = "Vera Lindqvist Trio"
        #expect(StableID.album(other) != StableID.album(key))
    }

    @Test("Where one name ends and the next begins is part of the identity")
    func boundaries() {
        let one = Album.Key(albumArtist: "ab", title: "c", year: nil)
        let two = Album.Key(albumArtist: "a", title: "bc", year: nil)
        #expect(StableID.album(one) != StableID.album(two))
    }

    @Test("No year and year zero are different albums")
    func nilYearIsNotZero() {
        var zero = key
        zero.year = 0
        var none = key
        none.year = nil
        #expect(StableID.album(zero) != StableID.album(none))
    }

    @Test("An artist and an album never share an id")
    func kindsDiffer() {
        let album = Album.Key(albumArtist: "Low", title: "", year: nil)
        #expect(StableID.album(album).dropFirst(3) != StableID.artist(named: "Low").dropFirst(3))
    }
}
