import Foundation

/// Turns the location a track is known by into a file an engine can open.
///
/// On the Mac the two are the same thing: `Track.url` is a file, and
/// `LocalTrackSource` hands it straight back. On a client of the library
/// server they are not. There `Track.url` names a track on another machine,
/// and the audio has to be fetched, with that machine's credentials and
/// pinned certificate, before anything can decode it.
///
/// The answer is always a local file rather than a stream, for two reasons
/// found in `docs/server-ios-recon.md`: neither engine Cadence uses can decode
/// from a network connection it does not own, and gapless playback needs the
/// next track on disk before the current one ends.
///
/// **Who calls this.** A `PlayerEngine`, not `PlaybackController`. The
/// controller's contract with an engine is already asynchronous in the way
/// that matters: `play(url:)` returns at once, the controller shows the track
/// as `.loading`, and the engine reports `.started` or `.failed` when it
/// knows. A remote engine does its fetching inside that window. Putting the
/// fetch in the controller instead would make its skip-on-failure loop and its
/// gapless handshake asynchronous for the Mac too, where there is nothing to
/// wait for.
public protocol TrackSource: Sendable {
    /// A file holding the audio for the track at `location`. Returns
    /// immediately when it is already on disk; otherwise when it has been
    /// fetched in full.
    ///
    /// Asking twice for the same location must not fetch twice: an engine
    /// asks once to pre-buffer the next track and again when it plays it.
    ///
    /// Throws `PlaybackError` where the failure is one the listener can be
    /// told about, and `CancellationError` when the enclosing task is
    /// cancelled, which a skip does.
    func fileURL(for location: URL) async throws -> URL
}

/// The source for a library that is already files on this machine.
public struct LocalTrackSource: TrackSource {
    public init() {}

    public func fileURL(for location: URL) async throws -> URL {
        // Anything else is a track from somewhere this source cannot reach.
        // Handing it to a decoder would surface as an opaque decode error.
        guard location.isFileURL else {
            throw PlaybackError.engine("This track is not stored on this device.")
        }
        return location
    }
}
