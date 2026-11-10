import Testing
import Foundation
@testable import CadenceCore

@Suite("Last.fm similar artists")
struct SimilarArtistLookupTests {

    private final class StubSource: SimilarArtistSource, @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var result: Result<[ExternalSimilarArtist], SimilarArtistError>
        let isConfigured: Bool

        init(_ result: Result<[ExternalSimilarArtist], SimilarArtistError>,
             configured: Bool = true) {
            self.result = result
            self.isConfigured = configured
        }

        func similarArtists(to artist: String) async throws -> [ExternalSimilarArtist] {
            lock.withLock { calls += 1 }
            return try result.get()
        }
    }

    private let beck = [ExternalSimilarArtist(name: "Beck", match: 0.8)]

    @Test("Parses names and string matches")
    func parse() throws {
        let json = """
            {"similarartists": {"artist": [
                {"name": "Beck", "match": "0.83"},
                {"name": "Portishead", "match": "1"}
            ], "@attr": {"artist": "Radiohead"}}}
            """
        let artists = try LastFMSimilarArtists.parse(Data(json.utf8))
        #expect(artists == [ExternalSimilarArtist(name: "Beck", match: 0.83),
                            ExternalSimilarArtist(name: "Portishead", match: 1)])
    }

    @Test("'Artist not found' is an empty answer; rate limiting is transient")
    func parseErrors() throws {
        #expect(try LastFMSimilarArtists.parse(Data(#"{"error": 6, "message": "x"}"#.utf8)) == [])
        #expect(throws: SimilarArtistError.transient("Last.fm error 29")) {
            try LastFMSimilarArtists.parse(Data(#"{"error": 29, "message": "x"}"#.utf8))
        }
    }

    @Test("A fresh cached answer is used without asking again")
    func cacheHit() async {
        let source = StubSource(.success(beck))
        let lookup = SimilarArtistLookup(source: source, cache: InMemorySimilarArtistCache())
        #expect(await lookup.similarArtists(to: "Radiohead") == beck)
        #expect(await lookup.similarArtists(to: "radiohead") == beck)
        #expect(source.calls == 1)
    }

    @Test("A stale answer is refetched, and kept when the refetch fails")
    func staleFallback() async throws {
        let cache = InMemorySimilarArtistCache()
        try await cache.storeSimilarArtists(beck, forKey: "radiohead",
                                            fetchedAt: Date(timeIntervalSince1970: 0))
        let source = StubSource(.failure(.transient("offline")))
        let lookup = SimilarArtistLookup(source: source, cache: cache, maxAge: 60)
        #expect(await lookup.similarArtists(to: "Radiohead") == beck)
        #expect(source.calls == 1)
    }

    @Test("A failed fetch is not cached, so the next one asks again")
    func failureNotCached() async {
        let source = StubSource(.failure(.transient("offline")))
        let lookup = SimilarArtistLookup(source: source, cache: InMemorySimilarArtistCache())
        #expect(await lookup.similarArtists(to: "Radiohead").isEmpty)
        #expect(await lookup.similarArtists(to: "Radiohead").isEmpty)
        #expect(source.calls == 2)
    }

    @Test("An unconfigured source is never called")
    func unconfigured() async {
        let source = StubSource(.success(beck), configured: false)
        let lookup = SimilarArtistLookup(source: source, cache: InMemorySimilarArtistCache())
        #expect(await lookup.similarArtists(to: "Radiohead").isEmpty)
        #expect(source.calls == 0)
    }

    @Test("Clearing the cache makes the next lookup ask Last.fm again")
    func clearCache() async {
        let source = StubSource(.success(beck))
        let lookup = SimilarArtistLookup(source: source, cache: InMemorySimilarArtistCache())
        _ = await lookup.similarArtists(to: "Radiohead")
        #expect(await lookup.cachedCount() == 1)
        try? await lookup.clearCache()
        #expect(await lookup.cachedCount() == 0)
        _ = await lookup.similarArtists(to: "Radiohead")
        #expect(source.calls == 2)
    }
}
