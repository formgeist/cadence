import Foundation

/// Somewhere outside the library that knows which artists are alike.
public protocol SimilarArtistSource: Sendable {
    /// False when the build carries no credentials, so the setting that uses
    /// it can say so instead of failing quietly on every page.
    var isConfigured: Bool { get }
    func similarArtists(to artist: String) async throws -> [ExternalSimilarArtist]
}

/// Last.fm's `artist.getSimilar`. Read-only and unsigned: it needs the app's
/// API key but no shared secret and no signed-in account, so it works whether
/// or not scrobbling is connected.
public struct LastFMSimilarArtists: SimilarArtistSource {
    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    /// How many Last.fm returns. More than the screen shows, because only
    /// the ones the library has are shown as cards.
    private let limit: Int

    public init(apiKey: String, session: URLSession = .shared, limit: Int = 100) {
        self.apiKey = apiKey
        self.session = session
        self.limit = limit
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    public func similarArtists(to artist: String) async throws -> [ExternalSimilarArtist] {
        guard isConfigured else { throw SimilarArtistError.notConfigured }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "method", value: "artist.getSimilar"),
            URLQueryItem(name: "artist", value: artist),
            // Lets Last.fm map a misspelt or variant name to the artist it
            // knows, instead of answering "artist not found".
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: components.url!)
        } catch {
            throw SimilarArtistError.transient(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
            throw SimilarArtistError.transient("Last.fm returned \(http.statusCode).")
        }
        return try Self.parse(data)
    }

    /// `{"similarartists": {"artist": [{"name": "…", "match": "0.83"}, …]}}`.
    /// `match` arrives as a string. Error 6 ("artist not found") is an answer —
    /// Last.fm has nothing — not a failure, so it parses to an empty list that
    /// can be cached like any other.
    static func parse(_ data: Data) throws -> [ExternalSimilarArtist] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimilarArtistError.malformedResponse
        }
        if let code = json["error"] as? Int {
            switch code {
            case 6: return []
            case 8, 11, 16, 29: throw SimilarArtistError.transient("Last.fm error \(code)")
            default: throw SimilarArtistError.rejected(json["message"] as? String ?? "Last.fm error \(code)")
            }
        }
        guard let container = json["similarartists"] as? [String: Any] else {
            throw SimilarArtistError.malformedResponse
        }
        // A single result comes back as an object rather than an array.
        let rows: [[String: Any]]
        if let list = container["artist"] as? [[String: Any]] {
            rows = list
        } else if let one = container["artist"] as? [String: Any] {
            rows = [one]
        } else {
            rows = []
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let match: Double
            if let text = row["match"] as? String { match = Double(text) ?? 0 }
            else if let number = row["match"] as? Double { match = number }
            else { match = 0 }
            return ExternalSimilarArtist(name: name, match: match)
        }
    }
}

public enum SimilarArtistError: Error, Equatable {
    case notConfigured
    /// Network down, rate limited, service hiccup — worth trying again later,
    /// and never cached.
    case transient(String)
    case rejected(String)
    case malformedResponse
}

// MARK: - Cache

/// Remembers outside answers so opening an artist twice asks once. Keyed by
/// `Similarity.key(for:)`.
public protocol SimilarArtistCache: Sendable {
    func cachedSimilarArtists(forKey key: String) async throws
        -> (artists: [ExternalSimilarArtist], fetchedAt: Date)?
    func storeSimilarArtists(_ artists: [ExternalSimilarArtist], forKey key: String,
                             fetchedAt: Date) async throws
    /// How many artists have an answer stored, for Preferences to report.
    func similarArtistCacheCount() async throws -> Int
    /// Forgets every stored answer, so each artist is asked about afresh the
    /// next time its page opens.
    func clearSimilarArtistCache() async throws
}

public final class InMemorySimilarArtistCache: SimilarArtistCache, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ([ExternalSimilarArtist], Date)] = [:]

    public init() {}

    public func cachedSimilarArtists(forKey key: String) async throws
        -> (artists: [ExternalSimilarArtist], fetchedAt: Date)? {
        lock.withLock { entries[key].map { ($0.0, $0.1) } }
    }

    public func storeSimilarArtists(_ artists: [ExternalSimilarArtist], forKey key: String,
                                    fetchedAt: Date) async throws {
        lock.withLock { entries[key] = (artists, fetchedAt) }
    }

    public func similarArtistCacheCount() async throws -> Int {
        lock.withLock { entries.count }
    }

    public func clearSimilarArtistCache() async throws {
        lock.withLock { entries.removeAll() }
    }
}

// MARK: - Lookup

/// The cache in front of the source: a fresh cached answer is used as is, a
/// stale one is refetched, and a failed fetch falls back to the stale answer
/// (or nothing) rather than surfacing an error on an artist page.
public actor SimilarArtistLookup {
    private let source: any SimilarArtistSource
    private let cache: any SimilarArtistCache
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    /// One request per artist at a time: the artist page and the album page
    /// below it can both ask while the first answer is in flight.
    private var inFlight: [String: Task<[ExternalSimilarArtist], Never>] = [:]

    /// Thirty days. Who sounds like whom moves slowly.
    public static let defaultMaxAge: TimeInterval = 30 * 24 * 60 * 60

    public init(source: any SimilarArtistSource, cache: any SimilarArtistCache,
                maxAge: TimeInterval = SimilarArtistLookup.defaultMaxAge,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.cache = cache
        self.maxAge = maxAge
        self.now = now
    }

    public nonisolated var isConfigured: Bool { source.isConfigured }

    public func cachedCount() async -> Int {
        (try? await cache.similarArtistCacheCount()) ?? 0
    }

    /// Drops every cached answer rather than refetching them all: asking
    /// Last.fm about hundreds of artists at once would run into its rate
    /// limit, and most of them may never be opened again. Each one is asked
    /// again the next time its page opens. A fetch already in flight still
    /// lands, which is fine — it is a fresh answer.
    public func clearCache() async throws {
        try await cache.clearSimilarArtistCache()
    }

    public func similarArtists(to artist: String) async -> [ExternalSimilarArtist] {
        let key = Similarity.key(for: artist)
        guard !key.isEmpty else { return [] }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await fetch(artist, key: key) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func fetch(_ artist: String, key: String) async -> [ExternalSimilarArtist] {
        let cached = try? await cache.cachedSimilarArtists(forKey: key)
        if let cached, now().timeIntervalSince(cached.fetchedAt) < maxAge {
            return cached.artists
        }
        guard source.isConfigured else { return cached?.artists ?? [] }
        do {
            let fresh = try await source.similarArtists(to: artist)
            try? await cache.storeSimilarArtists(fresh, forKey: key, fetchedAt: now())
            return fresh
        } catch {
            return cached?.artists ?? []
        }
    }
}
