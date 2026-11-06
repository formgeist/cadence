import Foundation

/// A suggestion for what to put on today: an album that has not had a turn in a
/// while, chosen by one of a few angles — a random one off the shelf, a release
/// year, a genre. Stable for the whole day, different tomorrow.
public struct AlbumOfTheDay: Equatable, Sendable {
    public var album: Album
    /// The angle, e.g. "Released in 2001".
    public var headline: String
    /// How long it has sat, e.g. "Not played in 4 months".
    public var detail: String

    /// Albums played within this window are left out while anything else remains.
    static let restingPeriod: TimeInterval = 14 * 86_400

    enum Angle: CaseIterable { case shelf, year, genre }

    public static func pick(from albums: [Album], history: [PlayRecord], now: Date,
                            calendar: Calendar = .current) -> AlbumOfTheDay? {
        guard !albums.isEmpty else { return nil }

        // Real albums before loose singles, when the library has both.
        let full = albums.filter { $0.tracks.count >= 3 }
        let library = full.isEmpty ? albums : full

        // Today's plays are ignored, so playing the pick does not take it out
        // of the pool and change the answer halfway through the day.
        let today = calendar.startOfDay(for: now)
        var lastPlayed: [Album.Key: Date] = [:]
        for play in history where play.playedAt < today {
            let key = play.albumKey
            if (lastPlayed[key] ?? .distantPast) < play.playedAt { lastPlayed[key] = play.playedAt }
        }

        let rested = library.filter {
            guard let last = lastPlayed[$0.key] else { return true }
            return now.timeIntervalSince(last) >= restingPeriod
        }
        // Everything was played lately: fall back to the less recent half.
        let pool: [Album]
        if rested.isEmpty {
            let oldestFirst = library.sorted {
                (lastPlayed[$0.key] ?? .distantPast) < (lastPlayed[$1.key] ?? .distantPast)
            }
            pool = Array(oldestFirst.prefix(max(1, library.count / 2)))
        } else {
            pool = rested
        }

        // The pool is sorted so the same day and library always pick the same
        // album, whatever order the albums arrived in.
        let stable = pool.sorted {
            ($0.albumArtist, $0.title, $0.year ?? 0) < ($1.albumArtist, $1.title, $1.year ?? 0)
        }

        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let seed = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        var rng = SplitMix64(seed: UInt64(seed))

        let angles = Angle.allCases
        let first = Int(rng.next() % UInt64(angles.count))
        for offset in 0..<angles.count {
            let angle = angles[(first + offset) % angles.count]
            if let choice = choose(angle, pool: stable, rng: &rng) {
                return AlbumOfTheDay(
                    album: choice.album,
                    headline: choice.headline,
                    detail: staleness(lastPlayed[choice.album.key], now: now))
            }
        }
        return nil
    }

    private static func choose(_ angle: Angle, pool: [Album],
                               rng: inout SplitMix64) -> (album: Album, headline: String)? {
        func one<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }

        switch angle {
        case .shelf:
            guard !pool.isEmpty else { return nil }
            return (one(pool), "Pulled from the shelf")
        case .year:
            let years = Set(pool.compactMap(\.year)).sorted()
            guard !years.isEmpty else { return nil }
            let year = one(years)
            return (one(pool.filter { $0.year == year }), "Released in \(year)")
        case .genre:
            let byGenre = Dictionary(grouping: pool) { $0.tracks.lazy.compactMap(\.genre).first }
                .compactMap { genre, albums in genre.map { ($0, albums) } }
                .filter { $0.1.count >= 2 }
                .sorted { $0.0 < $1.0 }
            guard !byGenre.isEmpty else { return nil }
            let (genre, albums) = one(byGenre)
            return (one(albums), "From your \(genre) shelf")
        }
    }

    static func staleness(_ last: Date?, now: Date) -> String {
        guard let last else { return "Not played yet" }
        let days = max(0, Int(now.timeIntervalSince(last) / 86_400))
        switch days {
        case ..<45: return "Not played in \(days) days"
        case ..<700: return "Not played in \(max(2, Int((Double(days) / 30.4).rounded()))) months"
        default: return "Not played in \(days / 365) years"
        }
    }
}

/// A small seeded generator, so the same date picks the same album on every
/// launch. `SystemRandomNumberGenerator` cannot be seeded.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
