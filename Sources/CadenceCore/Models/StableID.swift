import Foundation
import CryptoKit

/// Opaque string ids for the two things in the library that are aggregates
/// rather than rows: albums and artists.
///
/// A track has a stored UUID. An album is whatever tracks share an
/// `Album.Key`, and an artist is whatever tracks share an album-artist name,
/// so neither has a row to hang an id on. The library server still has to put
/// *something* on the wire that a client can hand back, and it must not be the
/// name itself: names contain anything, and an id a client can read invites it
/// to build one.
///
/// So the id is a digest of the identity the library already uses. That makes
/// it stable across rescans by construction, and it changes exactly when the
/// identity does: retagging an album's title makes it a different album here,
/// and it gets a different id.
///
/// **The derivation is a wire format.** Paired clients cache these ids, and
/// the `albumIdentity` and `artistIdentity` tables store them. Changing the
/// input string, the hash or the length orphans every one of them.
public enum StableID {

    /// `al-` and 32 hex characters.
    public static func album(_ key: Album.Key) -> String {
        // A nil year and the year 0 must not collide, hence the marker.
        let year = key.year.map(String.init) ?? "-"
        return "al-" + digest(["album", key.albumArtist, key.title, year])
    }

    /// `ar-` and 32 hex characters. `name` is the album-artist name, the same
    /// string `Artist.id` is.
    public static func artist(named name: String) -> String {
        "ar-" + digest(["artist", name])
    }

    /// The first 16 bytes of a SHA-256 over the parts, joined by a separator
    /// no tag can contain, so `("ab", "c")` and `("a", "bc")` differ.
    private static func digest(_ parts: [String]) -> String {
        let input = parts.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(input.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension Album.Key {
    public var stableID: String { StableID.album(self) }
}

extension Album {
    public var stableID: String { StableID.album(key) }
}

extension Artist {
    public var stableID: String { StableID.artist(named: name) }
}
