import Foundation

/// One listen, as the history keeps it: names and a time, nothing that points
/// into the library. Keyed by tags rather than by track id so the history
/// survives a rescan, a moved folder or a re-imported file.
public struct PlayRecord: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var albumTitle: String
    public var albumYear: Int?
    /// Seconds — the track's length, for the "hours listened" figure.
    public var duration: TimeInterval
    /// When the track started, not when it crossed the counting threshold.
    public var playedAt: Date

    public init(title: String, artist: String, albumArtist: String, albumTitle: String,
                albumYear: Int?, duration: TimeInterval, playedAt: Date) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.albumTitle = albumTitle
        self.albumYear = albumYear
        self.duration = duration
        self.playedAt = playedAt
    }

    public init(track: Track, playedAt: Date) {
        self.init(title: track.title, artist: track.artist, albumArtist: track.albumArtist,
                  albumTitle: track.albumTitle, albumYear: track.albumKey.year,
                  duration: track.duration, playedAt: playedAt)
    }

    public var albumKey: Album.Key {
        Album.Key(albumArtist: albumArtist, title: albumTitle, year: albumYear)
    }
}

/// Where the history lives. A boundary so previews and tests use memory and the
/// app uses the library database.
public protocol PlayLogStore: Sendable {
    func record(_ play: PlayRecord) async throws
    /// Every play, oldest first.
    func allPlays() async throws -> [PlayRecord]
}

public final class InMemoryPlayLogStore: PlayLogStore, @unchecked Sendable {
    private let lock = NSLock()
    private var plays: [PlayRecord]

    public init(plays: [PlayRecord] = []) { self.plays = plays }

    public func record(_ play: PlayRecord) async throws {
        lock.withLock { plays.append(play) }
    }

    public func allPlays() async throws -> [PlayRecord] {
        lock.withLock { plays.sorted { $0.playedAt < $1.playedAt } }
    }
}
