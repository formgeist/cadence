import Testing
import Foundation
@testable import CadenceCore

@Suite("Listening stats")
struct ListeningStatsTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    func play(_ title: String, artist: String = "A", album: String = "Album",
              year: Int? = 2001, daysAgo: Double = 1, duration: TimeInterval = 180) -> PlayRecord {
        PlayRecord(title: title, artist: artist, albumArtist: artist, albumTitle: album,
                   albumYear: year, duration: duration,
                   playedAt: Self.now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test("Top lists rank by plays, then recency")
    func ranking() {
        let history = [
            play("x", artist: "One", daysAgo: 3), play("x", artist: "One", daysAgo: 2),
            play("y", artist: "Two", daysAgo: 1),
            play("z", artist: "Three", daysAgo: 4),
        ]
        let stats = ListeningStats.compute(from: history, period: .allTime, now: Self.now)
        #expect(stats.topArtists.map(\.name) == ["One", "Two", "Three"])
        #expect(stats.topArtists.first?.plays == 2)
        #expect(stats.topTracks.first?.artist == "One")
        #expect(stats.plays == 4)
        #expect(stats.artistCount == 3)
    }

    @Test("A period leaves out older plays")
    func period() {
        let history = [play("old", daysAgo: 20), play("new", daysAgo: 2)]
        #expect(ListeningStats.compute(from: history, period: .week, now: Self.now).plays == 1)
        #expect(ListeningStats.compute(from: history, period: .month, now: Self.now).plays == 2)
    }

    @Test("Listening time adds up track lengths")
    func time() {
        let history = [play("a", duration: 100), play("b", duration: 50)]
        #expect(ListeningStats.compute(from: history, period: .allTime, now: Self.now)
            .listeningTime == 150)
    }

    @Test("Trend slices the period and keeps every play")
    func trend() {
        let history = [play("a", artist: "X", daysAgo: 0.5), play("b", artist: "Y", daysAgo: 0.6),
                       play("c", artist: "X", daysAgo: 3.5), play("d", daysAgo: 6.5)]
        let week = ListeningStats.compute(from: history, period: .week, now: Self.now).trend
        #expect(week.plays.count == 7)
        #expect(week.plays.reduce(0, +) == 4)
        #expect(week.plays.last == 2)
        #expect(week.artists.last == 2)
        #expect(week.seconds.reduce(0, +) == 720)

        let month = ListeningStats.compute(from: history, period: .month, now: Self.now).trend
        #expect(month.plays.count == 30)

        let all = ListeningStats.compute(from: history, period: .allTime, now: Self.now).trend
        #expect(all.plays.reduce(0, +) == 4)
        #expect(all.plays.count <= 30)
    }

    @Test("No history is empty")
    func empty() {
        #expect(ListeningStats.compute(from: [], period: .week, now: Self.now).isEmpty)
    }
}

@Suite("Album of the day")
struct AlbumOfTheDayTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func album(_ title: String, year: Int, genre: String? = nil) -> Album {
        let tracks = (1...4).map { n in
            Track(url: URL(fileURLWithPath: "/m/\(title)\(n).flac"), title: "\(title) \(n)",
                  artist: "Artist", albumTitle: title, genre: genre, year: year, duration: 200)
        }
        return Album(key: .init(albumArtist: "Artist", title: title, year: year), tracks: tracks)
    }

    func played(_ album: Album, daysAgo: Double) -> PlayRecord {
        PlayRecord(track: album.tracks[0],
                   playedAt: Self.now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test("Nothing to pick from an empty library")
    func empty() {
        #expect(AlbumOfTheDay.pick(from: [], history: [], now: Self.now) == nil)
    }

    @Test("The same day gives the same album, whatever the order")
    func stable() {
        let albums = (0..<12).map { album("Album \($0)", year: 1990 + $0) }
        let a = AlbumOfTheDay.pick(from: albums, history: [], now: Self.now, calendar: Self.calendar)
        let b = AlbumOfTheDay.pick(from: albums.reversed(), history: [], now: Self.now,
                                   calendar: Self.calendar)
        #expect(a != nil)
        #expect(a == b)
    }

    @Test("Recently played albums are skipped while others remain")
    func skipsRecent() {
        let fresh = album("Fresh", year: 2005)
        let stale = album("Stale", year: 2001)
        let history = [played(fresh, daysAgo: 3), played(stale, daysAgo: 200)]
        for offset in 0..<20 {
            let day = Self.now.addingTimeInterval(Double(offset) * 86_400)
            let pick = AlbumOfTheDay.pick(from: [fresh, stale], history: history,
                                          now: day, calendar: Self.calendar)
            // Fresh was last played 3 days before `now`; the first days must
            // never choose it. Later days may, once it has rested.
            if offset < 10 { #expect(pick?.album.title == "Stale") }
        }
    }

    @Test("Playing today's pick does not change it")
    func playingDoesNotChange() {
        let albums = (0..<12).map { album("Album \($0)", year: 1990 + $0) }
        let first = AlbumOfTheDay.pick(from: albums, history: [], now: Self.now,
                                       calendar: Self.calendar)!
        let after = AlbumOfTheDay.pick(from: albums, history: [played(first.album, daysAgo: 0)],
                                       now: Self.now, calendar: Self.calendar)
        #expect(after?.album == first.album)
    }

    @Test("Staleness reads in days, months and years")
    func staleness() {
        let now = Self.now
        #expect(AlbumOfTheDay.staleness(nil, now: now) == "Not played yet")
        #expect(AlbumOfTheDay.staleness(now.addingTimeInterval(-20 * 86_400), now: now) == "Not played in 20 days")
        #expect(AlbumOfTheDay.staleness(now.addingTimeInterval(-120 * 86_400), now: now) == "Not played in 4 months")
        #expect(AlbumOfTheDay.staleness(now.addingTimeInterval(-800 * 86_400), now: now) == "Not played in 2 years")
    }
}

@MainActor
@Suite("PlayLogController")
struct PlayLogControllerTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    typealias Rig = (log: PlayLogController, playback: PlaybackController,
                     store: InMemoryPlayLogStore, engine: SpyEngine)

    func rig() -> Rig {
        let store = InMemoryPlayLogStore()
        let log = PlayLogController(store: store, now: { Self.now })
        let engine = SpyEngine()
        let playback = PlaybackController(engine: engine)
        playback.onTrackStarted = { [weak log] in log?.trackStarted($0) }
        log.attach(to: playback)
        return (log, playback, store, engine)
    }

    /// Starts the track and tells the controller the engine is playing.
    func start(_ r: Rig, _ t: Track) async {
        r.playback.play(t, in: [t])
        await r.engine.emit(.started(t.url))
        for _ in 0..<5 { await Task.yield() }
    }

    func track(seconds: TimeInterval = 200) -> Track {
        Track(url: URL(fileURLWithPath: "/m/t.flac"), title: "T", artist: "Artist",
              albumTitle: "Album", duration: seconds)
    }

    func listen(_ r: Rig, seconds: Int) {
        for _ in 0..<seconds {
            r.playback.seek(to: r.playback.progress.elapsed + 1)
            r.log.poll()
        }
    }

    @Test("A track is logged once half of it has been heard")
    func logsAtHalf() async throws {
        let r = rig()
        let t = track()
        await start(r, t)
        listen(r, seconds: 99)
        #expect(r.log.plays.isEmpty)
        listen(r, seconds: 2)
        #expect(r.log.plays.count == 1)
        listen(r, seconds: 30)
        #expect(r.log.plays.count == 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(try await r.store.allPlays().count == 1)
    }

    @Test("Tracks under thirty seconds are never logged")
    func shortTracks() async {
        let r = rig()
        let t = track(seconds: 20)
        await start(r, t)
        listen(r, seconds: 20)
        #expect(r.log.plays.isEmpty)
    }
}
