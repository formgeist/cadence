import SwiftUI
import UniformTypeIdentifiers
import CadenceCore

// MARK: - Dragging tracks

extension UTType {
    /// Cadence's own drag type, declared in the bundle's Info.plist by
    /// `Scripts/make-app.sh`. Deliberately not `.text`: track ids mean nothing
    /// outside this app, and dropping an album into TextEdit should do nothing
    /// rather than paste a column of UUIDs.
    static let cadenceTracks = UTType(exportedAs: "com.formgeist.cadence.track-ids")
}

/// Tracks in flight between a list and a playlist.
///
/// Ids rather than whole tracks: the drop resolves them against the library it
/// already has, so a payload formed before a rescan removed a file adds what
/// still exists instead of a ghost row.
struct TrackSelection: Codable, Transferable {
    var trackIDs: [Track.ID]

    init(_ trackIDs: [Track.ID]) { self.trackIDs = trackIDs }
    init(_ tracks: [Track]) { self.trackIDs = tracks.map(\.id) }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cadenceTracks)
    }
}

// MARK: - Menus

/// "Add to Playlist" wherever tracks are listed. A submenu rather than a
/// dialog: choosing the destination is the whole interaction, and a library
/// with three playlists should not open a window to pick one of them.
///
/// The model is a property rather than `@Environment`. Most of these live
/// inside a `.contextMenu`, which macOS turns into an NSMenu — the same kind
/// of separate presentation that already forced `NewPlaylistSheet` to be
/// handed the model by hand. Taking it as a parameter makes the question moot.
struct AddToPlaylistMenu: View {
    var model: AppModel
    var tracks: [Track]

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(model.playlists) { playlist in
                Button(playlist.name) {
                    Task { await model.addTracks(tracks.map(\.id), to: playlist.id) }
                }
            }
            if !model.playlists.isEmpty { Divider() }
            // Seeded, so the tracks this menu was opened on end up in the
            // playlist it makes rather than being forgotten by the sheet.
            Button("New Playlist…") { model.naming = .create(seed: tracks) }
        }
        .disabled(tracks.isEmpty)
    }
}

/// Everything you can do to a playlist without opening it. Shared by the
/// sidebar row, the Playlists shelf and the detail screen's ellipsis, so the
/// three cannot drift into offering different verbs.
struct PlaylistActionButtons: View {
    /// Passed in for the same reason as `AddToPlaylistMenu`'s: these hang off
    /// `.contextMenu` more often than not.
    var model: AppModel
    var playback: PlaybackController
    var playlist: Playlist

    private var tracks: [Track] { model.tracks(in: playlist) }

    var body: some View {
        Button("Play") {
            guard let first = tracks.first else { return }
            playback.play(first, in: tracks)
        }
        .disabled(tracks.isEmpty)

        Button("Shuffle") { playback.shuffle(tracks) }
            .disabled(tracks.isEmpty)

        Button("Add to Queue") { playback.appendToQueue(tracks) }
            .disabled(tracks.isEmpty)

        Divider()

        // An empty playlist has nothing to play, but renaming and deleting it
        // are exactly what you want to do with one.
        Button("Rename…") { model.naming = .rename(playlist) }
        Button("Delete", role: .destructive) {
            model.playlistPendingDeletion = playlist
        }
    }
}
