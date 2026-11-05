import Testing
import Foundation
@testable import CadenceCore

@Suite("Spotify playlist import")
struct SpotifyImportTests {

    private func track(_ title: String, by artist: String, album: String = "Album",
                       seconds: TimeInterval = 200) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(artist)/\(title).flac"),
              title: title, artist: artist, albumTitle: album, duration: seconds)
    }

    // MARK: Links

    @Test("Share links, URIs and bare ids all give the playlist id",
          arguments: [
            "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc123",
            "https://open.spotify.com/intl-de/playlist/37i9dQZF1DXcBWIGoYBM5M",
            "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
            "  37i9dQZF1DXcBWIGoYBM5M\n",
          ])
    func playlistID(input: String) {
        #expect(SpotifyAPI.playlistID(from: input) == "37i9dQZF1DXcBWIGoYBM5M")
    }

    @Test("Album links and other sites are refused",
          arguments: [
            "https://open.spotify.com/album/37i9dQZF1DXcBWIGoYBM5M",
            "https://example.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
            "spotify:album:37i9dQZF1DXcBWIGoYBM5M",
            "not a link",
          ])
    func rejectsOtherLinks(input: String) {
        #expect(SpotifyAPI.playlistID(from: input) == nil)
    }

    // MARK: Responses

    @Test("A page reads `item`, falls back to `track`, and skips episodes and gaps")
    func parsePage() {
        let page: [String: Any] = ["items": [
            ["item": ["type": "track", "name": "Teardrop", "duration_ms": 330_000,
                      "artists": [["name": "Massive Attack"]],
                      "album": ["name": "Mezzanine"]]],
            ["track": ["type": "track", "name": "Angel",
                       "artists": [["name": "Massive Attack"]]]],
            ["item": ["type": "episode", "name": "A podcast"]],
            ["item": NSNull()],
        ]]
        let tracks = SpotifyAPI.parseTracks(page)
        #expect(tracks == [
            SpotifyTrack(title: "Teardrop", artists: ["Massive Attack"],
                         album: "Mezzanine", duration: 330),
            SpotifyTrack(title: "Angel", artists: ["Massive Attack"]),
        ])
    }

    @Test("A refresh that does not rotate the refresh token keeps the old one")
    func refreshKeepsToken() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let token = try SpotifyAPI.parseToken(
            ["access_token": "new", "expires_in": 3600.0],
            previousRefreshToken: "old-refresh", now: now)
        #expect(token == SpotifyToken(accessToken: "new", refreshToken: "old-refresh",
                                      expiresAt: now.addingTimeInterval(3600)))
    }

    @Test("The callback is refused when its state does not match")
    func callbackState() throws {
        let callback = URL(string: "cadence://spotify-callback?code=abc&state=xyz")!
        #expect(try SpotifyAPI.authorizationCode(from: callback, expectedState: "xyz") == "abc")
        #expect(throws: SpotifyError.stateMismatch) {
            try SpotifyAPI.authorizationCode(from: callback, expectedState: "other")
        }
        let denied = URL(string: "cadence://spotify-callback?error=access_denied&state=xyz")!
        #expect(throws: SpotifyError.accessDenied) {
            try SpotifyAPI.authorizationCode(from: denied, expectedState: "xyz")
        }
    }

    /// Expected value from `openssl dgst -sha256 -binary | base64`, made URL-safe.
    @Test("The PKCE challenge is the URL-safe SHA-256 of the verifier")
    func codeChallenge() {
        #expect(SpotifyAPI.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWzS1lEk")
                == "wrsk-TYkrIlpvMzBg2l5m-bwBskd86WKRYr9Dg6vxOw")
    }

    // MARK: Matching

    @Test("Spelling differences between Spotify and tags still match")
    func normalisedMatches() {
        let library = [
            track("Halo", by: "Beyonce"),
            track("Get Lucky", by: "Daft Punk feat. Pharrell Williams"),
            track("Wonderwall", by: "Oasis"),
            track("Mrs. Robinson", by: "Simon & Garfunkel"),
            track("Karma Police", by: "Radiohead"),
        ]
        let matcher = PlaylistMatcher(library: library)
        let result = matcher.match([
            SpotifyTrack(title: "Halo", artists: ["Beyoncé"]),
            SpotifyTrack(title: "Get Lucky (feat. Pharrell Williams)",
                         artists: ["Daft Punk", "Pharrell Williams"]),
            SpotifyTrack(title: "Wonderwall - Remastered", artists: ["Oasis"]),
            SpotifyTrack(title: "Mrs Robinson", artists: ["Simon and Garfunkel"]),
            SpotifyTrack(title: "Karma Police", artists: ["The Radiohead"]),
        ])
        #expect(result.matched.map(\.title)
                == ["Halo", "Get Lucky", "Wonderwall", "Mrs. Robinson", "Karma Police"])
        #expect(result.missing.isEmpty)
    }

    @Test("Songs the library lacks are skipped, and order and repeats are kept")
    func skipsMissing() {
        let a = track("A Song", by: "Artist")
        let b = track("B Song", by: "Artist")
        let matcher = PlaylistMatcher(library: [a, b])
        let result = matcher.match([
            SpotifyTrack(title: "B Song", artists: ["Artist"]),
            SpotifyTrack(title: "Not Here", artists: ["Artist"]),
            SpotifyTrack(title: "A Song", artists: ["Artist"]),
            SpotifyTrack(title: "B Song", artists: ["Artist"]),
        ])
        #expect(result.matched.map(\.id) == [b.id, a.id, b.id])
        #expect(result.missing.map(\.title) == ["Not Here"])
    }

    @Test("Same title by another artist is not a match")
    func artistMustMatch() {
        let matcher = PlaylistMatcher(library: [track("Hurt", by: "Johnny Cash"),
                                                track("Angel", by: "Simone")])
        #expect(matcher.bestMatch(for: SpotifyTrack(title: "Hurt",
                                                    artists: ["Nine Inch Nails"])) == nil)
        #expect(matcher.bestMatch(for: SpotifyTrack(title: "Angel", artists: ["Simon"])) == nil)
    }

    @Test("An exact title beats a stripped one, then the album, then the length")
    func ranking() {
        let live = track("Song (Live)", by: "Band", album: "Live at Home", seconds: 260)
        let studio = track("Song", by: "Band", album: "Studio", seconds: 200)
        let other = track("Song", by: "Band", album: "Hits", seconds: 300)
        let matcher = PlaylistMatcher(library: [live, studio, other])

        #expect(matcher.bestMatch(for: SpotifyTrack(title: "Song (Live)", artists: ["Band"]))?.id
                == live.id)
        #expect(matcher.bestMatch(for: SpotifyTrack(title: "Song", artists: ["Band"],
                                                    album: "Hits", duration: 200))?.id
                == other.id)
        #expect(matcher.bestMatch(for: SpotifyTrack(title: "Song - 2011 Remaster",
                                                    artists: ["Band"], duration: 205))?.id
                == studio.id)
    }
}
