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

/// What follows the cursor while tracks are in flight.
///
/// Without an explicit preview, `.draggable` lifts the view it is attached to.
/// An album's track row is as wide as the window, so dragging one hauled a
/// 700pt bar across the screen to drop it on a 180pt sidebar row — the pointer
/// ended up somewhere in the middle of a slab that covered the target.
///
/// No `ArtworkView` here on purpose. It reads `ArtworkLoader` out of the
/// environment and traps if it is missing, and a drag preview is rendered
/// outside the ordinary view tree — the same uncertainty that made the menus
/// take their model as a parameter. A glyph cannot fail.
struct TrackDragPreview: View {
    var systemImage: String
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.Palette.accent)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.thumb, style: .continuous)
                        .fill(Tokens.Palette.accentDim)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Tokens.Typography.sans(11.5, .semibold))
                    .foregroundStyle(Color(hex: 0xE6E6EC))
                    .lineLimit(1)
                Text(detail)
                    .font(Tokens.Typography.sans(10, .medium))
                    .foregroundStyle(Tokens.Palette.textMuted)
                    .lineLimit(1)
            }
            // Capped rather than flexible: a long title should truncate, not
            // grow the chip back to the width this exists to avoid.
            .frame(maxWidth: 150, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.popover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.borderStrong, lineWidth: 1)
        }
        // It floats over whatever is underneath, which is usually a dark grid
        // of covers. Without a lift it reads as part of the page.
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    /// One track on its way to a playlist.
    static func track(_ track: Track) -> TrackDragPreview {
        TrackDragPreview(systemImage: "music.note",
                         title: track.title, detail: track.artist)
    }

    /// A whole record. The count is the part worth knowing before you let go.
    static func album(_ album: Album) -> TrackDragPreview {
        let count = album.trackCount == 1 ? "1 track" : "\(album.trackCount) tracks"
        return TrackDragPreview(systemImage: "square.stack",
                                title: album.title, detail: count)
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
