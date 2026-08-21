import Foundation
import AppKit
import MediaPlayer
import CadenceCore
import CadenceLibrary

/// Publishes what is playing to the system, and accepts the system's transport
/// commands back.
///
/// This is what makes the media keys, Control Center, the Now Playing widget
/// and the AirPods stem work — PLAN.md §6 phase 5. All of it needs a real
/// bundle identity, which is why it waited for `Scripts/make-app.sh`.
///
/// It observes rather than being called: the controller stays unaware that any
/// of this exists, so nothing about system integration leaks into playback.
@MainActor
final class NowPlayingCoordinator {

    private let playback: PlaybackController
    private let artwork: DiskArtworkStore?

    private var observation: Task<Void, Never>?
    private var lastPublishedTrack: Track.ID?
    private var lastPublishedState: Bool?
    private var artworkTask: Task<Void, Never>?

    init(playback: PlaybackController, artwork: DiskArtworkStore?) {
        self.playback = playback
        self.artwork = artwork
        registerCommands()
        startObserving()
    }

    deinit {
        observation?.cancel()
        artworkTask?.cancel()
    }

    // MARK: - Commands in

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.playback.isPlaying { self.playback.togglePlayPause() }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.playback.isPlaying { self.playback.togglePlayPause() }
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.playback.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.playback.next()
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.playback.previous()
            return .success
        }

        // Scrubbing from Control Center.
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.playback.seek(to: event.positionTime)
            return .success
        }

        // Seeking by holding a key is not something this app offers, and
        // leaving them enabled makes the system advertise controls that do
        // nothing.
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    // MARK: - State out

    /// Polls rather than subscribing: `@Observable` has no stream to observe
    /// from outside a view, and the interesting changes — track, play state —
    /// are compared before publishing, so the cost is a comparison twice a
    /// second rather than a system call.
    private func startObserving() {
        observation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.publishIfChanged()
            }
        }
    }

    private func publishIfChanged() {
        guard let track = playback.currentTrack else {
            if lastPublishedTrack != nil {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                MPNowPlayingInfoCenter.default().playbackState = .stopped
                lastPublishedTrack = nil
                lastPublishedState = nil
            }
            return
        }

        let isPlaying = playback.isPlaying
        let trackChanged = track.id != lastPublishedTrack
        let stateChanged = isPlaying != lastPublishedState

        // Elapsed time does not need republishing on a timer: the system
        // extrapolates from the rate and the last known position, and
        // republishing every tick makes the Control Center scrubber stutter.
        guard trackChanged || stateChanged else { return }

        lastPublishedTrack = track.id
        lastPublishedState = isPlaying
        publish(track, isPlaying: isPlaying, includeArtwork: trackChanged)
    }

    private func publish(_ track: Track, isPlaying: Bool, includeArtwork: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPMediaItemPropertyAlbumArtist: track.albumArtist,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playback.progress.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let number = track.trackNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = number
        }
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[
            MPMediaItemPropertyArtwork], !includeArtwork {
            info[MPMediaItemPropertyArtwork] = existing
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        if includeArtwork { attachArtwork(for: track) }
    }

    /// Builds the artwork MediaPlayer will ask for later.
    ///
    /// Deliberately `nonisolated`, and deliberately closing over `Data` rather
    /// than an `NSImage`. MediaPlayer invokes this handler on its own queue
    /// while serialising the Now Playing dictionary — so a handler formed in a
    /// main-actor context carries an isolation check that fails there and traps
    /// the process. Every track with cover art would have crashed the app.
    private nonisolated static func artwork(from data: Data, size: CGSize) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: size) { requested in
            // A fresh image per request: handing the same AppKit object to
            // whatever queue asks for it is the other half of the problem.
            NSImage(data: data) ?? NSImage(size: requested)
        }
    }

    /// Artwork is fetched off the main actor and merged in when it arrives, so
    /// a cold cache never delays the rest of the Now Playing update.
    private func attachArtwork(for track: Track) {
        artworkTask?.cancel()
        guard let artwork, let id = track.artworkID else {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }

        artworkTask = Task { [weak self] in
            let data = try? await artwork.thumbnail(for: id, maxPixelSize: 600)
            guard !Task.isCancelled, let data, let image = NSImage(data: data),
                  let self, self.playback.currentTrack?.id == track.id else { return }

            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = Self.artwork(from: data, size: image.size)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
