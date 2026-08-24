import Foundation

// MARK: - Audio format

/// What a file actually contains. Kept separate from `Track` so the same
/// value can be summarised across an album without recomputing it per row.
public struct AudioFormat: Hashable, Sendable {
    public enum Codec: Hashable, Sendable {
        case flac, alac, aiff, wav, mp3, aac, opus, vorbis
        case other(String)

        public var name: String {
            switch self {
            case .flac: "FLAC"
            case .alac: "ALAC"
            case .aiff: "AIFF"
            case .wav: "WAV"
            case .mp3: "MP3"
            case .aac: "AAC"
            case .opus: "Opus"
            case .vorbis: "Vorbis"
            case .other(let n): n.uppercased()
            }
        }

        public var isLossless: Bool {
            switch self {
            case .flac, .alac, .aiff, .wav: true
            case .mp3, .aac, .opus, .vorbis: false
            case .other: false
            }
        }

        /// Round-trips `name`, so a codec survives a database column.
        public init(name: String) {
            switch name.uppercased() {
            case "FLAC": self = .flac
            case "ALAC": self = .alac
            case "AIFF": self = .aiff
            case "WAV": self = .wav
            case "MP3": self = .mp3
            case "AAC": self = .aac
            case "OPUS": self = .opus
            case "VORBIS": self = .vorbis
            default: self = .other(name)
            }
        }
    }

    public var codec: Codec
    /// Hertz. 44100, 96000, …
    public var sampleRate: Double
    /// Nil for lossy formats, which have no meaningful bit depth.
    public var bitDepth: Int?
    public var channelCount: Int

    public init(codec: Codec, sampleRate: Double, bitDepth: Int? = nil, channelCount: Int = 2) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
    }

    public var isLossless: Bool { codec.isLossless }

    /// `96` for 96000, `44.1` for 44100 — trailing zeroes dropped.
    public var kilohertz: String {
        let khz = sampleRate / 1000
        return khz == khz.rounded()
            ? String(Int(khz))
            : String(format: "%.1f", khz)
    }

    /// Compact form for table columns and badges: `24/96`, `16/44.1`.
    public var shortDescription: String {
        guard let bitDepth else { return "\(kilohertz) kHz" }
        return "\(bitDepth)/\(kilohertz)"
    }

    /// Long form for the now-playing pane: `24-bit / 96 kHz`.
    public var longDescription: String {
        guard let bitDepth else { return "\(kilohertz) kHz" }
        return "\(bitDepth)-bit / \(kilohertz) kHz"
    }

    /// What the immersive view and album header badge show: `FLAC · 24-bit / 96 kHz`.
    public var badgeDescription: String { "\(codec.name) · \(longDescription)" }

    public static let cd = AudioFormat(codec: .flac, sampleRate: 44100, bitDepth: 16)
    public static let hiRes = AudioFormat(codec: .flac, sampleRate: 96000, bitDepth: 24)
}

// MARK: - ReplayGain

public struct ReplayGain: Hashable, Sendable {
    /// Decibels of adjustment.
    public var trackGain: Double?
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?

    public init(trackGain: Double? = nil, trackPeak: Double? = nil,
                albumGain: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
    }
}

// MARK: - Artwork

public struct Artwork: Identifiable, Hashable, Sendable {
    /// Content address — SHA-256 of the image bytes. Identical covers across a
    /// box set collapse to one entry on disk.
    public typealias ID = String

    public var id: ID
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(id: ID, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var dimensionsDescription: String { "\(pixelWidth) × \(pixelHeight)" }
}

// MARK: - Track

public struct Track: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    /// Security-scoped bookmark. Without this the user's music folder is
    /// inaccessible on second launch — see PLAN.md §7.
    public var bookmark: Data?

    public var title: String
    public var artist: String
    public var albumArtist: String
    public var albumTitle: String
    /// Classical files where the composer matters more than the performer.
    public var composer: String?
    public var genre: String?
    public var year: Int?

    public var trackNumber: Int?
    public var trackCount: Int?
    public var discNumber: Int?
    public var discCount: Int?

    public var duration: TimeInterval
    public var format: AudioFormat
    public var artworkID: Artwork.ID?
    public var replayGain: ReplayGain?
    /// Set when the tags say so, or inferred when an album's tracks disagree
    /// about their artist.
    public var isCompilation: Bool
    public var dateAdded: Date
    /// Size + mtime digest, used by the scanner to skip unchanged files.
    public var fingerprint: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        bookmark: Data? = nil,
        title: String,
        artist: String,
        albumArtist: String? = nil,
        albumTitle: String,
        composer: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        trackCount: Int? = nil,
        discNumber: Int? = nil,
        discCount: Int? = nil,
        duration: TimeInterval,
        format: AudioFormat = .cd,
        artworkID: Artwork.ID? = nil,
        replayGain: ReplayGain? = nil,
        isCompilation: Bool = false,
        dateAdded: Date = Date(),
        fingerprint: String? = nil
    ) {
        self.id = id
        self.url = url
        self.bookmark = bookmark
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist ?? artist
        self.albumTitle = albumTitle
        self.composer = composer
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.discNumber = discNumber
        self.discCount = discCount
        self.duration = duration
        self.format = format
        self.artworkID = artworkID
        self.replayGain = replayGain
        self.isCompilation = isCompilation
        self.dateAdded = dateAdded
        self.fingerprint = fingerprint
    }

    public var albumKey: Album.Key {
        Album.Key(albumArtist: albumArtist, title: albumTitle, year: year)
    }

    /// What the track-row secondary line should say. On a single-artist album
    /// repeating the album artist under every title is noise; where the artists
    /// differ it is the most useful column on the screen.
    public func rowSubtitle(showingArtist: Bool) -> String? {
        if let composer, !composer.isEmpty { return composer }
        if showingArtist || artist != albumArtist { return artist }
        return nil
    }
}

// MARK: - Album

public struct Album: Identifiable, Hashable, Sendable {
    /// Title alone merges every *Greatest Hits*; adding the year keeps
    /// remasters separate from originals. See PLAN.md §7.
    public struct Key: Hashable, Sendable {
        public var albumArtist: String
        public var title: String
        public var year: Int?

        public init(albumArtist: String, title: String, year: Int?) {
            self.albumArtist = albumArtist
            self.title = title
            self.year = year
        }
    }

    public var key: Key
    public var id: Key { key }
    public var tracks: [Track]

    public init(key: Key, tracks: [Track]) {
        self.key = key
        self.tracks = tracks
    }

    public var title: String { key.title }
    public var albumArtist: String { key.albumArtist }
    public var year: Int? { key.year }

    public var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    public var trackCount: Int { tracks.count }
    public var artworkID: Artwork.ID? { tracks.compactMap(\.artworkID).first }

    /// A record by many artists. Deliberately harder to satisfy than "the
    /// COMPILATION tag is set": deluxe editions in the wild carry that tag
    /// while every track is by the same band, and labelling those a
    /// compilation is visibly wrong. A tag is believed only when the track
    /// artists back it up.
    public var isCompilation: Bool {
        if albumArtist.caseInsensitiveCompare("Various Artists") == .orderedSame {
            return true
        }
        return tracks.contains(where: \.isCompilation) && distinctArtistCount > 1
    }

    /// Whether track rows should carry an artist line. Separate from
    /// `isCompilation` on purpose: a self-titled album with one guest feature
    /// is not a compilation, but that one row still needs to say who is on it.
    public var showsTrackArtists: Bool {
        tracks.contains { $0.artist != albumArtist }
    }

    public var distinctArtistCount: Int { Set(tracks.map(\.artist)).count }

    public var discCount: Int {
        let discs = Set(tracks.compactMap(\.discNumber))
        return max(discs.count, 1)
    }

    public var hasMultipleDiscs: Bool { discCount > 1 }

    /// Tracks grouped by disc, in disc then track order. A single-disc album
    /// returns one group with a nil number so the view can skip the header.
    public var discs: [Disc] {
        guard hasMultipleDiscs else {
            return [Disc(number: nil, tracks: tracks.sorted(by: Track.inAlbumOrder))]
        }
        let grouped = Dictionary(grouping: tracks) { $0.discNumber ?? 1 }
        return grouped.keys.sorted().map { number in
            Disc(number: number, tracks: (grouped[number] ?? []).sorted(by: Track.inAlbumOrder))
        }
    }

    public struct Disc: Identifiable, Hashable, Sendable {
        public var number: Int?
        public var tracks: [Track]
        public var id: Int { number ?? 0 }
    }

    /// The album's headline quality. Where tracks disagree — a hi-res album
    /// with one CD-rate bonus track — the highest wins, because that is what
    /// the listener bought it for.
    public var dominantFormat: AudioFormat? {
        tracks.map(\.format).max {
            ($0.bitDepth ?? 0, $0.sampleRate) < ($1.bitDepth ?? 0, $1.sampleRate)
        }
    }

    /// Groups tracks already in hand into albums, title-sorted the way
    /// `LibraryStore.albums()` orders them. For a caller that already has
    /// every track loaded, this is the same result without a second
    /// round trip through the store.
    public static func grouped(from tracks: [Track]) -> [Album] {
        Dictionary(grouping: tracks, by: \.albumKey)
            .map { Album(key: $0.key, tracks: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

extension Track {
    /// Disc, then track number, then title — with untagged tracks last rather
    /// than sorted to the top as zero.
    public static func inAlbumOrder(_ a: Track, _ b: Track) -> Bool {
        let (ad, bd) = (a.discNumber ?? 1, b.discNumber ?? 1)
        if ad != bd { return ad < bd }
        let (an, bn) = (a.trackNumber ?? .max, b.trackNumber ?? .max)
        if an != bn { return an < bn }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}

// MARK: - Artist

public struct Artist: Identifiable, Hashable, Sendable {
    public var name: String
    public var id: String { name }
    public var albumCount: Int
    public var trackCount: Int
    /// Distinct codec names across the artist's tracks, for the right-hand
    /// column in the artists list.
    public var formats: [String]

    public init(name: String, albumCount: Int, trackCount: Int, formats: [String]) {
        self.name = name
        self.albumCount = albumCount
        self.trackCount = trackCount
        self.formats = formats
    }

    /// `4 albums · 41 tracks`
    public var summary: String {
        let albums = albumCount == 1 ? "1 album" : "\(albumCount) albums"
        let tracks = trackCount == 1 ? "1 track" : "\(trackCount) tracks"
        return "\(albums) · \(tracks)"
    }

    public var formatSummary: String { formats.joined(separator: " · ") }

    /// `The Beatles` files under B, the way a record shop would shelve it.
    public static func stripArticle(_ name: String) -> String {
        for article in ["The ", "A ", "An "] where name.hasPrefix(article) {
            return String(name.dropFirst(article.count))
        }
        return name
    }
}

// MARK: - Playlist

public struct Playlist: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var trackIDs: [Track.ID]
    public var duration: TimeInterval

    public init(id: UUID = UUID(), name: String, trackIDs: [Track.ID], duration: TimeInterval) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.duration = duration
    }

    public var summary: String {
        trackIDs.count == 1 ? "1 track" : "\(trackIDs.count) tracks"
    }
}

// MARK: - Duration formatting

/// Years a music file could plausibly carry. Anything outside this is junk
/// metadata — `9999`, `0000`, a track number that landed in the date field —
/// and showing it in an album header is worse than showing nothing.
///
/// Shared so that every reader agrees: the same tag must not become a
/// different year depending on which reader happened to open the file.
public enum PlausibleYear {
    public static let range = 1000...3000

    public static func validated(_ year: Int?) -> Int? {
        guard let year, range.contains(year) else { return nil }
        return year
    }
}

public enum DurationFormat {
    /// `5:38`, and `1:02:11` once an hour is in play — for track rows and the
    /// transport clock.
    public static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// `-2:26`. The now-playing pane counts down, so the minus is part of it.
    public static func remaining(_ seconds: TimeInterval) -> String {
        "-" + clock(max(0, seconds))
    }

    /// `42 min`, `3 hr 10 min` — album and playlist totals, where seconds are
    /// noise.
    public static func approximate(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h) hr" : "\(h) hr \(String(format: "%02d", m)) min"
    }

    /// `412 GB` for the sidebar footer.
    public static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: count)
    }
}
