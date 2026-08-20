import Foundation

// MARK: - Mock engine

/// Advances a clock instead of decoding anything. Everything in the interface
/// can be built and demoed against this with no audio code compiled at all —
/// see PLAN.md §1.
///
/// It also fakes the gapless handshake: when a prepared track exists and the
/// clock runs out, it reports `advancedToNext` rather than `finished`, so the
/// controller's gapless path is exercised in the app you can actually click.
@MainActor
public final class MockPlayerEngine: PlayerEngine {

    public let events: AsyncStream<EngineEvent>
    public let positions: AsyncStream<TimeInterval>

    private let eventSink: AsyncStream<EngineEvent>.Continuation
    private let positionSink: AsyncStream<TimeInterval>.Continuation

    public var volume: Double = 1.0
    public private(set) var currentTime: TimeInterval = 0

    /// Wall-clock seconds per second. Raise it to watch a 59-minute track
    /// reach its end without waiting 59 minutes.
    public var rate: Double

    private var currentDuration: TimeInterval = 0
    private var nextUp: (url: URL, duration: TimeInterval)?
    private var isRunning = false
    private var ticker: Task<Void, Never>?

    private static let tick = Swift.Duration.milliseconds(100)

    public init(rate: Double = 1.0) {
        self.rate = rate
        (events, eventSink) = AsyncStream.makeStream()
        (positions, positionSink) = AsyncStream.makeStream()
    }

    deinit {
        // The ticker holds self weakly and exits on the next tick. Finishing
        // the streams releases whoever is iterating them.
        eventSink.finish()
        positionSink.finish()
    }

    public func play(url: URL, duration: TimeInterval, gain: Double) throws {
        currentTime = 0
        currentDuration = duration
        nextUp = nil
        isRunning = true
        eventSink.yield(.started(url))
        eventSink.yield(.wantsNextTrack)
        startTicking()
    }

    public func prepareNext(url: URL, duration: TimeInterval, gain: Double) throws {
        nextUp = (url, duration)
    }

    public func clearNext() { nextUp = nil }

    public func pause() {
        guard isRunning else { return }
        isRunning = false
        ticker?.cancel()
        ticker = nil
        eventSink.yield(.paused)
    }

    public func resume() {
        guard !isRunning, currentDuration > 0 else { return }
        isRunning = true
        eventSink.yield(.resumed)
        startTicking()
    }

    public func stop() {
        isRunning = false
        ticker?.cancel()
        ticker = nil
        currentTime = 0
        currentDuration = 0
        nextUp = nil
    }

    public func seek(to time: TimeInterval) {
        currentTime = min(max(0, time), currentDuration)
        positionSink.yield(currentTime)
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MockPlayerEngine.tick)
                guard let self, self.isRunning else { return }
                self.advanceClock()
            }
        }
    }

    private func advanceClock() {
        currentTime += 0.1 * rate
        guard currentTime < currentDuration else {
            reachEnd()
            return
        }
        positionSink.yield(currentTime)
    }

    private func reachEnd() {
        if let nextUp {
            // The gapless path: the engine moves on by itself and tells the
            // controller after the fact.
            currentTime = 0
            currentDuration = nextUp.duration
            let url = nextUp.url
            self.nextUp = nil
            eventSink.yield(.advancedToNext(url))
            eventSink.yield(.wantsNextTrack)
        } else {
            isRunning = false
            ticker?.cancel()
            ticker = nil
            currentTime = currentDuration
            eventSink.yield(.finished)
        }
    }
}

// MARK: - In-memory library

/// A `LibraryStore` over an array, so the app runs end to end before GRDB
/// exists. Search is a naive substring match — the real store uses FTS5.
public actor InMemoryLibraryStore: LibraryStore {
    private let tracks: [Track]
    private let storedPlaylists: [Playlist]

    public init(tracks: [Track], playlists: [Playlist] = []) {
        self.tracks = tracks
        self.storedPlaylists = playlists
    }

    public func allTracks() async throws -> [Track] { tracks }

    public func albums() async throws -> [Album] {
        Dictionary(grouping: tracks, by: \.albumKey)
            .map { Album(key: $0.key, tracks: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func album(for key: Album.Key) async throws -> Album? {
        let matching = tracks.filter { $0.albumKey == key }
        return matching.isEmpty ? nil : Album(key: key, tracks: matching)
    }

    public func artists() async throws -> [Artist] {
        Dictionary(grouping: tracks, by: \.albumArtist)
            .map { name, tracks in
                Artist(
                    name: name,
                    albumCount: Set(tracks.map(\.albumKey)).count,
                    trackCount: tracks.count,
                    formats: Array(Set(tracks.map(\.format.codec.name))).sorted()
                )
            }
            .sorted {
                Artist.stripArticle($0.name)
                    .localizedStandardCompare(Artist.stripArticle($1.name)) == .orderedAscending
            }
    }

    public func albums(byArtist name: String) async throws -> [Album] {
        try await albums().filter { $0.albumArtist == name }
    }

    public func playlists() async throws -> [Playlist] { storedPlaylists }

    public func tracks(matching query: String) async throws -> [Track] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return tracks.filter {
            $0.title.lowercased().contains(needle)
                || $0.artist.lowercased().contains(needle)
                || $0.albumTitle.lowercased().contains(needle)
                || ($0.composer?.lowercased().contains(needle) ?? false)
        }
    }

    public func upsert(_ tracks: [Track]) async throws {
        // The preview store is read-only; the real store writes here.
    }

    public func librarySize() async throws -> Int64 {
        // Roughly what lossless costs: ~1.1 MB per second of 24/96 stereo,
        // ~0.5 MB for 16/44.1. Enough to make the sidebar figure plausible.
        tracks.reduce(Int64(0)) { total, track in
            let perSecond = (track.format.bitDepth ?? 16) >= 24 ? 1_100_000.0 : 500_000.0
            return total + Int64(track.duration * perSecond)
        }
    }
}

// MARK: - Preview data

/// A deliberately awkward sample library. Mocks drawn against tidy metadata
/// fall apart on first contact with a real collection, so this one contains
/// the content that breaks naive layouts — see PLAN.md §6, phase 4.
public enum PreviewData {

    // MARK: Building blocks

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/preview/Music/\(name).flac")
    }

    private static func track(
        _ title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        seconds: TimeInterval,
        number: Int,
        of total: Int? = nil,
        disc: Int? = nil,
        discs: Int? = nil,
        year: Int? = nil,
        composer: String? = nil,
        genre: String? = nil,
        format: AudioFormat = .hiRes,
        artwork: Artwork.ID? = "art-placeholder",
        compilation: Bool = false,
        gain: Double? = -6.4
    ) -> Track {
        Track(
            url: url("\(album)-\(number)-\(title)"),
            title: title,
            artist: artist,
            albumArtist: albumArtist ?? artist,
            albumTitle: album,
            composer: composer,
            genre: genre,
            year: year,
            trackNumber: number,
            trackCount: total,
            discNumber: disc,
            discCount: discs,
            duration: seconds,
            format: format,
            artworkID: artwork,
            replayGain: gain.map { ReplayGain(trackGain: $0, albumGain: $0 + 0.3) },
            isCompilation: compilation
        )
    }

    // MARK: The album the design was drawn against

    public static let slowHours: [Track] = {
        let songs: [(String, TimeInterval)] = [
            ("Morning Static", 252), ("Slow Hours", 338), ("Anhedonia", 234),
            ("Cassette Sunlight", 362), ("Undertow", 287), ("Ninth Ward", 201),
            ("Paper Radio", 311), ("Hollow Season", 273), ("Sound of the Slow Hours", 302),
        ]
        return songs.enumerated().map { index, song in
            track(
                song.0,
                artist: "Vera Lindqvist",
                album: "Sound of the Slow Hours",
                seconds: song.1,
                number: index + 1,
                of: songs.count,
                year: 2023,
                genre: "Ambient",
                // One CD-rate track on a hi-res album, so the quality column
                // has something to say.
                format: index % 3 == 1 ? .hiRes : .cd
            )
        }
    }()

    // MARK: The cases that break layouts

    /// One track, 59 minutes. Breaks progress bars that assume a scale of
    /// minutes and track lists that assume many rows.
    public static let longformDrone: [Track] = [
        track(
            "Nocturne for a Long Night",
            artist: "Halvard Ås",
            album: "Nocturne for a Long Night",
            seconds: 3552,
            number: 1,
            of: 1,
            year: 2019,
            genre: "Drone",
            artwork: nil
        )
    ]

    /// A title long enough to wrap three lines at display size.
    public static let longTitle: [Track] = (1...4).map { index in
        track(
            ["Terminal Approach", "Shipping Forecast (Dogger, Fisher)",
             "Departures Board", "Night Mail"][index - 1],
            artist: "Beacon Field",
            album: "Music for Airports, Shipping Forecasts and Other Ambient Transmissions Recorded Between 1978 and 1983",
            seconds: [421, 512, 388, 604][index - 1],
            number: index,
            of: 4,
            year: 1983,
            genre: "Ambient",
            format: .cd
        )
    }

    /// Three discs. Anything that renders a flat track list gets this wrong.
    public static let boxSet: [Track] = {
        var result: [Track] = []
        let discTitles = [
            ["Overture", "Sea Interlude I", "Sea Interlude II", "Storm"],
            ["Aria", "Chorus of the Borough", "Passacaglia"],
            ["Rehearsal Fragment", "Interview, 1962", "Final Performance"],
        ]
        for (discIndex, titles) in discTitles.enumerated() {
            for (trackIndex, title) in titles.enumerated() {
                result.append(track(
                    title,
                    artist: "Cyrille Marchand",
                    album: "The Complete Aldeburgh Recordings",
                    albumArtist: "Cyrille Marchand",
                    seconds: TimeInterval(180 + trackIndex * 97 + discIndex * 41),
                    number: trackIndex + 1,
                    of: titles.count,
                    disc: discIndex + 1,
                    discs: 3,
                    year: 1976,
                    // Composer matters more than performer here.
                    composer: ["Benjamin Britten", "Benjamin Britten", "Peter Grimes (arr.)"][discIndex],
                    genre: "Classical",
                    format: .cd
                ))
            }
        }
        return result
    }()

    /// Various Artists. Every row needs its own artist line, which the
    /// single-artist album layout suppresses.
    public static let compilation: [Track] = {
        let entries: [(String, String, TimeInterval)] = [
            ("Glacier Mouth", "Delta Sleep Choir", 294),
            ("Hydrofoil", "Ansel Vaughn", 336),
            ("Bells of Osaka", "Bells of Osaka", 401),
            ("Static Garden", "Alva Noto Ensemble", 268),
            ("Paper Radio (Reprise)", "Colm Bregha", 189),
        ]
        return entries.enumerated().map { index, entry in
            track(
                entry.0,
                artist: entry.1,
                album: "Nordic Ambient, Vol. 4",
                albumArtist: "Various Artists",
                seconds: entry.2,
                number: index + 1,
                of: entries.count,
                year: 2024,
                genre: "Ambient",
                format: index == 2 ? AudioFormat(codec: .alac, sampleRate: 44100, bitDepth: 16) : .hiRes,
                compilation: true
            )
        }
    }()

    /// A remaster that must not merge with the original — same artist, same
    /// title, different year. See `Album.Key`.
    public static let remaster: [Track] = slowHours.prefix(5).enumerated().map { index, source in
        track(
            source.title,
            artist: "Vera Lindqvist",
            album: "Sound of the Slow Hours",
            seconds: source.duration + 1,
            number: index + 1,
            of: 5,
            year: 2025,
            genre: "Ambient"
        )
    }

    /// No artwork anywhere, to exercise the placeholder path in the grid.
    public static let noArtwork: [Track] = (1...6).map { index in
        track(
            ["Undertow, Pt. I", "Undertow, Pt. II", "Undertow, Pt. III",
             "Low Water", "Spring Tide", "Undertow (Coda)"][index - 1],
            artist: "Delta Sleep Choir",
            album: "Undertow, Vol. II",
            seconds: TimeInterval(220 + index * 33),
            number: index,
            of: 6,
            year: 2021,
            genre: "Ambient",
            artwork: nil
        )
    }

    /// Ordinary records, so the library isn't all edge cases.
    public static let ordinary: [Track] = {
        let albums: [(String, String, Int, Int)] = [
            ("Northerly", "Beacon Field", 2022, 7),
            ("Halo Pressing", "Ansel Vaughn", 2020, 6),
            ("Quiet Machines", "Cyrille Marchand", 2018, 8),
            ("Static Garden", "Alva Noto Ensemble", 2024, 5),
            ("Paper Radio", "Colm Bregha", 2017, 6),
        ]
        return albums.flatMap { title, artist, year, count in
            (1...count).map { index in
                track(
                    "\(title) \(["I", "II", "III", "IV", "V", "VI", "VII", "VIII"][index - 1])",
                    artist: artist,
                    album: title,
                    seconds: TimeInterval(190 + index * 44),
                    number: index,
                    of: count,
                    year: year,
                    genre: "Ambient",
                    format: index.isMultiple(of: 2) ? .hiRes : .cd
                )
            }
        }
    }()

    // MARK: Assembled library

    public static let tracks: [Track] =
        slowHours + longformDrone + longTitle + boxSet
        + compilation + remaster + noArtwork + ordinary

    public static let playlists: [Playlist] = [
        Playlist(name: "Late Desk", trackIDs: Array(tracks.prefix(42).map(\.id)), duration: 11_400),
        Playlist(name: "Reference Tracks", trackIDs: Array(tracks.prefix(18).map(\.id)), duration: 4_920),
        Playlist(name: "Sunday Vinyl Rips", trackIDs: tracks.map(\.id), duration: 17_280),
        Playlist(name: "Headphones Only", trackIDs: Array(tracks.prefix(27).map(\.id)), duration: 7_440),
        Playlist(name: "24/96 Showcase", trackIDs: Array(tracks.prefix(12).map(\.id)), duration: 3_480),
    ]

    public static func store() -> InMemoryLibraryStore {
        InMemoryLibraryStore(tracks: tracks, playlists: playlists)
    }

    public static func album(_ title: String) -> Album? {
        let matching = tracks.filter { $0.albumTitle == title }
        guard let first = matching.first else { return nil }
        return Album(key: first.albumKey, tracks: matching)
    }

    /// A controller mid-playback, three tracks into the design's album — the
    /// state every now-playing mock is drawn in.
    @MainActor
    public static func controller(rate: Double = 1.0) -> PlaybackController {
        let controller = PlaybackController(engine: MockPlayerEngine(rate: rate))
        if slowHours.indices.contains(2) {
            controller.play(slowHours[2], in: slowHours)
            controller.seek(to: 88)
        }
        return controller
    }
}
