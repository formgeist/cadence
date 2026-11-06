import Foundation

public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week = "7 days"
    case month = "30 days"
    case allTime = "All time"

    public var id: String { rawValue }

    /// The first instant the period covers, or `nil` for all time.
    public func start(now: Date) -> Date? {
        switch self {
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        case .allTime: nil
        }
    }
}

/// What the Home screen shows of the listening history: headline figures and
/// the top artists, albums and tracks of one period.
public struct ListeningStats: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var name: String
        /// The artist, for an album or a track; `nil` for an artist entry.
        public var artist: String?
        /// Set on album entries, so a row can open the album.
        public var albumKey: Album.Key?
        public var plays: Int
        public var id: String { name + "\u{1F}" + (artist ?? "") }

        public init(name: String, artist: String? = nil, albumKey: Album.Key? = nil, plays: Int) {
            self.name = name
            self.artist = artist
            self.albumKey = albumKey
            self.plays = plays
        }
    }

    /// One value per time slice across the period, oldest first — the shape
    /// behind each headline figure's sparkline.
    public struct Trend: Sendable, Equatable {
        public var plays: [Double]
        /// Seconds listened in each slice.
        public var seconds: [Double]
        /// Distinct artists heard in each slice.
        public var artists: [Double]
    }

    public var plays: Int
    public var trend: Trend
    public var listeningTime: TimeInterval
    public var artistCount: Int
    public var topArtists: [Entry]
    public var topAlbums: [Entry]
    public var topTracks: [Entry]

    public var isEmpty: Bool { plays == 0 }

    public static let limit = 5

    public static func compute(from history: [PlayRecord], period: StatsPeriod,
                               now: Date) -> ListeningStats {
        let plays = period.start(now: now).map { cutoff in
            history.filter { $0.playedAt >= cutoff }
        } ?? history

        /// Counts plays per key and returns the top few: most plays, then most
        /// recently played, then name — so ties never shuffle between launches.
        func top<Key: Hashable>(_ keyOf: (PlayRecord) -> Key,
                                entry: (Key) -> Entry) -> [Entry] {
            var counts: [Key: (count: Int, latest: Date)] = [:]
            for play in plays {
                let key = keyOf(play)
                let seen = counts[key]
                counts[key] = ((seen?.count ?? 0) + 1, max(seen?.latest ?? .distantPast, play.playedAt))
            }
            return counts
                .map { key, value in
                    var item = entry(key)
                    item.plays = value.count
                    return (item, value.latest)
                }
                .sorted {
                    if $0.0.plays != $1.0.plays { return $0.0.plays > $1.0.plays }
                    if $0.1 != $1.1 { return $0.1 > $1.1 }
                    return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
                }
                .prefix(limit)
                .map(\.0)
        }

        struct TrackKey: Hashable { var title: String; var artist: String }

        return ListeningStats(
            plays: plays.count,
            trend: trend(of: plays, period: period, now: now),
            listeningTime: plays.reduce(0) { $0 + $1.duration },
            artistCount: Set(plays.map(\.artist)).count,
            topArtists: top({ $0.artist }) { Entry(name: $0, plays: 0) },
            topAlbums: top({ $0.albumKey }) {
                Entry(name: $0.title, artist: $0.albumArtist, albumKey: $0, plays: 0)
            },
            topTracks: top({ TrackKey(title: $0.title, artist: $0.artist) }) {
                Entry(name: $0.title, artist: $0.artist, plays: 0)
            })
    }

    /// Slices the period into equal windows ending at `now`: a day each for
    /// 7 and 30 days, and for all time up to thirty windows from the first play.
    static func trend(of plays: [PlayRecord], period: StatsPeriod, now: Date) -> Trend {
        let day: TimeInterval = 86_400
        let start: Date
        let count: Int
        switch period {
        case .week: start = now.addingTimeInterval(-7 * day); count = 7
        case .month: start = now.addingTimeInterval(-30 * day); count = 30
        case .allTime:
            start = plays.map(\.playedAt).min() ?? now.addingTimeInterval(-day)
            count = min(30, max(1, Int(ceil(now.timeIntervalSince(start) / day))))
        }
        let width = max(1, now.timeIntervalSince(start)) / Double(count)

        var counts = [Double](repeating: 0, count: count)
        var seconds = [Double](repeating: 0, count: count)
        var artists = [Set<String>](repeating: [], count: count)
        for play in plays {
            let slot = min(count - 1, max(0, Int(play.playedAt.timeIntervalSince(start) / width)))
            counts[slot] += 1
            seconds[slot] += play.duration
            artists[slot].insert(play.artist)
        }
        return Trend(plays: counts, seconds: seconds, artists: artists.map { Double($0.count) })
    }
}
