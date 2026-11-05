import Foundation

/// Finds the library track behind each entry of a playlist from somewhere
/// else, by title and artist. Entries with no match are reported, not
/// guessed at: a playlist with a wrong song in it is worse than one with a
/// song missing.
///
/// Spotify and file tags spell the same song differently often enough that an
/// exact comparison misses most of a playlist — "Song - Remastered 2011"
/// against "Song", "Beyoncé" against "Beyonce", "Song (feat. X)" against
/// "Song". So the comparison runs on a normalised form, and a title also
/// matches with its version suffixes stripped. An exact title wins over a
/// stripped one; among equals, the same album wins, then the closest length.
public struct PlaylistMatcher: Sendable {
    public struct Result: Sendable {
        /// In playlist order, one per matched entry — a song listed twice
        /// comes back twice.
        public var matched: [Track]
        public var missing: [SpotifyTrack]
    }

    private struct Candidate {
        var track: Track
        var title: String
        var coreTitle: String
        var artists: [String]
        var album: String
    }

    private let byCoreTitle: [String: [Candidate]]

    public init(library: [Track]) {
        var index: [String: [Candidate]] = [:]
        for track in library {
            let candidate = Candidate(
                track: track,
                title: Self.normalize(track.title),
                coreTitle: Self.coreTitle(track.title),
                artists: [track.artist, track.albumArtist].map(Self.normalize),
                album: Self.coreTitle(track.albumTitle))
            index[candidate.coreTitle, default: []].append(candidate)
        }
        byCoreTitle = index
    }

    public func match(_ entries: [SpotifyTrack]) -> Result {
        var result = Result(matched: [], missing: [])
        for entry in entries {
            if let track = bestMatch(for: entry) {
                result.matched.append(track)
            } else {
                result.missing.append(entry)
            }
        }
        return result
    }

    public func bestMatch(for entry: SpotifyTrack) -> Track? {
        let core = Self.coreTitle(entry.title)
        guard !core.isEmpty, let pool = byCoreTitle[core] else { return nil }
        let title = Self.normalize(entry.title)
        let artists = entry.artists.map(Self.normalize).filter { !$0.isEmpty }
        let album = entry.album.map(Self.coreTitle)

        let ranked = pool
            .filter { Self.artistsOverlap(artists, $0.artists) }
            .map { candidate -> (Candidate, Int, TimeInterval) in
                var score = 0
                if candidate.title == title { score += 2 }
                if let album, album == candidate.album { score += 1 }
                let gap = entry.duration > 0 && candidate.track.duration > 0
                    ? abs(entry.duration - candidate.track.duration)
                    : .greatestFiniteMagnitude
                return (candidate, score, gap)
            }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.2 < rhs.2
            }
        return ranked.first?.0.track
    }

    // MARK: - Normalising

    /// Any credited Spotify artist against the track or album artist. Also
    /// matches when one contains the other as whole words, so "Simon" does
    /// not match "Simone" but "Daft Punk" matches "Daft Punk feat. Pharrell".
    static func artistsOverlap(_ spotify: [String], _ library: [String]) -> Bool {
        guard !spotify.isEmpty else { return true }
        for lhs in spotify where !lhs.isEmpty {
            for rhs in library where !rhs.isEmpty {
                if lhs == rhs { return true }
                let (short, long) = lhs.count < rhs.count ? (lhs, rhs) : (rhs, lhs)
                if " \(long) ".contains(" \(short) ") { return true }
            }
        }
        return false
    }

    /// Lowercased, accents folded, `&` read as `and`, punctuation dropped and
    /// whitespace collapsed. A leading "The " is dropped as well — tags and
    /// Spotify disagree about it for band names.
    static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        let words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let trimmed = words.first == "the" && words.count > 1 ? Array(words.dropFirst()) : words
        return trimmed.joined(separator: " ")
    }

    /// The title without what versions add to it: anything in brackets, and
    /// anything after a spaced dash ("Song - Remastered 2011", "Song - Live").
    /// Falls back to the full title when stripping would leave nothing, as
    /// with a song called "(Untitled)".
    static func coreTitle(_ title: String) -> String {
        var stripped = title
        if let dash = stripped.range(of: " - ") ?? stripped.range(of: " – ") {
            stripped = String(stripped[..<dash.lowerBound])
        }
        stripped = stripped.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let feat = stripped.range(of: #"\s+(feat\.?|ft\.|featuring)\s.*$"#,
                                     options: [.regularExpression, .caseInsensitive]) {
            stripped.removeSubrange(feat)
        }
        let core = normalize(stripped)
        return core.isEmpty ? normalize(title) : core
    }
}
