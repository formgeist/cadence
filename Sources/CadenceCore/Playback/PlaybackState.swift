import Foundation

/// The discrete part of playback. Changes rarely — on play, pause, track
/// change — and is safe for the whole view tree to observe.
///
/// Position is deliberately *not* in here. It fires ~10×/second, and sharing a
/// channel with state changes would invalidate every view ten times a second.
/// See `PlaybackProgress` and PLAN.md §4.
public enum PlaybackState: Hashable, Sendable {
    case idle
    case loading(Track.ID)
    case playing(Track.ID)
    case paused(Track.ID)
    case failed(PlaybackError)

    public var trackID: Track.ID? {
        switch self {
        case .loading(let id), .playing(let id), .paused(let id): id
        case .idle, .failed: nil
        }
    }

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    public var isActive: Bool { trackID != nil }
}

/// The continuous part. Updated at the engine's position tick rate.
public struct PlaybackProgress: Hashable, Sendable {
    public var elapsed: TimeInterval
    public var duration: TimeInterval

    public init(elapsed: TimeInterval = 0, duration: TimeInterval = 0) {
        self.elapsed = elapsed
        self.duration = duration
    }

    public static let zero = PlaybackProgress()

    /// 0…1, clamped. Zero-length tracks report 0 rather than NaN.
    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    public var remaining: TimeInterval { max(0, duration - elapsed) }
    public var elapsedText: String { DurationFormat.clock(elapsed) }
    public var remainingText: String { DurationFormat.remaining(remaining) }
}

public enum RepeatMode: String, CaseIterable, Sendable {
    case off, all, one

    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

public enum ShuffleMode: String, CaseIterable, Sendable {
    case off, on

    public var isOn: Bool { self == .on }
    public var toggled: ShuffleMode { self == .on ? .off : .on }
}

/// Which ReplayGain tags to honour. `.album` preserves the relative levels
/// within a record, which is the point of listening to one.
public enum ReplayGainMode: String, CaseIterable, Sendable {
    case off, track, album

    public var label: String {
        switch self {
        case .off: "Off"
        case .track: "Track"
        case .album: "Album"
        }
    }
}

/// A track the queue moved past because the engine could not open it, and why.
///
/// Top level rather than nested in `PlaybackController` so it carries no actor
/// isolation of its own: the controller is `@MainActor`, and a record of what
/// went wrong should be free to travel to a log or a report that is not.
public struct SkippedTrack: Identifiable, Hashable, Sendable {
    public let track: Track
    public let reason: PlaybackError

    public init(track: Track, reason: PlaybackError) {
        self.track = track
        self.reason = reason
    }

    public var id: Track.ID { track.id }
}

public enum PlaybackError: Error, Hashable, Sendable {
    case fileMissing(URL)
    case bookmarkStale(URL)
    case unsupportedFormat(String)
    case outputDeviceLost
    case engine(String)

    public var message: String {
        switch self {
        case .fileMissing(let url):
            "The file for this track has moved or been deleted.\n\(url.lastPathComponent)"
        case .bookmarkStale(let url):
            "Cadence no longer has permission to read this folder.\n\(url.lastPathComponent)"
        case .unsupportedFormat(let name):
            "This file is in a format Cadence can't decode (\(name))."
        case .outputDeviceLost:
            "The audio output device went away. Playback stopped."
        case .engine(let detail):
            detail
        }
    }

    /// One clause, for a message that has already named the track — a skip
    /// notice reads "Skipped “Bitches Brew” — the file has moved", where
    /// `message` would repeat the filename back at a title already on screen.
    public var reasonPhrase: String {
        switch self {
        case .fileMissing:
            "the file has moved or been deleted"
        case .bookmarkStale:
            "Cadence can no longer read that folder"
        case .unsupportedFormat(let name):
            "Cadence can't decode \(name)"
        case .outputDeviceLost:
            "the audio output device went away"
        case .engine(let detail):
            detail
        }
    }

    /// Tells a file that is *gone* from one the decoder merely refused. The
    /// engine only knows that the open failed; the filesystem knows why, and
    /// the two want different words and different remedies.
    ///
    /// Order matters: an unreadable file inside a folder the sandbox has lost
    /// exists but cannot be opened, and reporting that as a decode failure
    /// sends the user looking for a corrupt rip that is perfectly fine.
    public static func diagnosing(_ error: Error, at url: URL) -> PlaybackError {
        let manager = FileManager.default
        guard url.isFileURL else { return wrapping(error) }
        if !manager.fileExists(atPath: url.path) { return .fileMissing(url) }
        if !manager.isReadableFile(atPath: url.path) { return .bookmarkStale(url) }
        return wrapping(error)
    }

    private static func wrapping(_ error: Error) -> PlaybackError {
        error as? PlaybackError ?? .engine(error.localizedDescription)
    }
}
