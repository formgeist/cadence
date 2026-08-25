import SwiftUI
import AppKit
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
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Tokens.Palette.accent)
                .frame(width: 18, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.thumb, style: .continuous)
                        .fill(Tokens.Palette.accentDim)
                }

            // One line, not two. A drag preview is clipped to its source
            // view's bounds, and an album track row with nothing to say on its
            // second line is only about 34pt tall — a two-line chip had its
            // bottom sawn off on exactly the rows that are most common.
            (Text(title).foregroundColor(Color(hex: 0xE6E6EC))
                + Text("  ·  ").foregroundColor(Tokens.Palette.textFaint)
                + Text(detail).foregroundColor(Tokens.Palette.textMuted))
                .font(Tokens.Typography.sans(11.5, .semibold))
                .lineLimit(1)
                // Capped rather than flexible: a long title should truncate,
                // not grow the chip back to the width this exists to avoid.
                .frame(maxWidth: 190, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.popover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.borderStrong, lineWidth: 1)
        }
    }

    /// What the chip occupies vertically: an 18pt glyph plus 5pt above and
    /// below. Kept well under the ~34pt of the shortest album track row,
    /// because a preview is clipped to its source view's bounds and a chip
    /// that does not fit is one with its bottom cut off.
    ///
    /// No shadow, for the same reason: it would fall outside those bounds and
    /// render as a flat edge rather than a lift. The border separates it.
    static let height: CGFloat = 28

    /// Places the chip inside a transparent stand-in the size of the view being
    /// dragged, with the chip itself sitting where the pointer is.
    ///
    /// macOS lifts a drag preview from the source view's bounds. When the
    /// preview is a different size it gets flown in from wherever the source
    /// sits — which on an album card is a visible slide from the middle of the
    /// cover into the pointer, and on a full-width row is a slide from the
    /// middle of the window. Matching the source's size means the preview
    /// starts exactly over it and never travels.
    ///
    /// Both offsets are clamped inside the stand-in, since anything outside it
    /// is cut off: a drag begun on a row's time column, or low on a cover,
    /// puts the chip at the edge rather than through it.
    func anchored(in size: CGSize, at pointer: CGPoint) -> some View {
        fixedSize()
            .offset(x: min(max(0, pointer.x - 14), max(0, size.width - Self.width)),
                    y: min(max(0, pointer.y - Self.height / 2),
                           max(0, size.height - Self.height)))
            .frame(width: max(size.width, 1),
                   height: max(size.height, Self.height),
                   alignment: .topLeading)
    }

    /// The chip at its widest — 190pt of text plus glyph, spacing and padding.
    /// Only used to keep the clamps off the trailing edge; a shorter title
    /// simply leaves more room.
    static let width: CGFloat = 231

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

/// Every menu the app offers, as data.
///
/// Keeping the verbs here rather than in the views is what stops the sidebar
/// row, the shelf card and the detail screen's ellipsis drifting into offering
/// different things.
///
/// The model is a parameter rather than `@Environment` throughout. These are
/// built inside a closure the menu calls when it opens, which may be long
/// after the view that supplied it went out of scope — the same separate
/// presentation that already forced `NewPlaylistSheet` to be handed its model
/// by hand.
@MainActor
enum PlaylistMenu {

    /// The symbol for each verb, in one place so the panel and the context
    /// menus cannot pick different ones for the same word.
    enum Symbol {
        static let play = "play.fill"
        static let shuffle = "shuffle"
        static let addToQueue = "text.append"
        static let addToPlaylist = "music.note.list"
        static let newPlaylist = "plus"
        static let rename = "pencil"
        static let delete = "trash"
        static let remove = "minus.circle"
        static let replayGain = "waveform"
        static let revealInFinder = "folder"
        static let getInfo = "info.circle"
    }

    /// "Add to Playlist" wherever tracks are listed. A submenu rather than a
    /// dialog: choosing the destination is the whole interaction, and a
    /// library with three playlists should not open a window to pick one.
    static func destinations(model: AppModel, tracks: [Track]) -> MenuItem {
        var items: [MenuItem] = model.playlists.map { playlist in
            .action(playlist.name, Symbol.addToPlaylist, enabled: !tracks.isEmpty) {
                Task { await model.addTracks(tracks.map(\.id), to: playlist.id) }
            }
        }
        if !model.playlists.isEmpty { items.append(.separator) }
        // Seeded, so the tracks this menu was opened on end up in the playlist
        // it makes rather than being forgotten by the sheet.
        items.append(.action("New Playlist…", Symbol.newPlaylist,
                             enabled: !tracks.isEmpty) {
            model.naming = .create(seed: tracks)
        })

        return .submenu("Add to Playlist", Symbol.addToPlaylist, items: items)
    }

    /// Everything you can do to a playlist without opening it.
    static func actions(model: AppModel,
                        playback: PlaybackController,
                        playlist: Playlist) -> [MenuItem] {
        let tracks = model.tracks(in: playlist)
        let hasTracks = !tracks.isEmpty

        return [
            .action("Play", Symbol.play, enabled: hasTracks) {
                guard let first = tracks.first else { return }
                playback.play(first, in: tracks)
            },
            .action("Shuffle", Symbol.shuffle, enabled: hasTracks) {
                playback.shuffle(tracks)
            },
            .action("Add to Queue", Symbol.addToQueue, enabled: hasTracks) {
                playback.appendToQueue(tracks)
            },
            .separator,
            // An empty playlist has nothing to play, but renaming and deleting
            // it are exactly what you want to do with one.
            .action("Rename…", Symbol.rename) {
                model.naming = .rename(playlist)
            },
            // Its own group rather than sharing Rename's. The one destructive
            // verb should never be a slip away from the one beside it.
            .separator,
            .action("Delete", Symbol.delete, shortcut: "⌫", destructive: true) {
                model.playlistPendingDeletion = playlist
            },
        ]
    }

    /// The album header's ＋: the queue, or a playlist.
    static func albumAdditions(model: AppModel,
                               playback: PlaybackController,
                               tracks: [Track]) -> [MenuItem] {
        [
            .action("Add to Queue", Symbol.addToQueue, enabled: !tracks.isEmpty) {
                playback.appendToQueue(tracks)
            },
            .separator,
            destinations(model: model, tracks: tracks),
        ]
    }

    /// A whole record, right-clicked on the Albums shelf.
    static func album(_ album: Album,
                      model: AppModel,
                      playback: PlaybackController) -> [MenuItem] {
        let tracks = album.discs.flatMap(\.tracks)
        return [
            .action("Play", Symbol.play) { playback.play(album) },
            .action("Shuffle", Symbol.shuffle) { playback.shuffle(album) },
            .action("Add to Queue", Symbol.addToQueue) {
                playback.appendToQueue(tracks)
            },
            .separator,
            destinations(model: model, tracks: tracks),
            .separator,
            .action("Reveal in Finder", Symbol.revealInFinder, enabled: !tracks.isEmpty) {
                NSWorkspace.shared.activateFileViewerSelecting(tracks.map(\.url))
            },
            .separator,
            .action("Remove from Library", Symbol.delete,
                    destructive: true, enabled: !tracks.isEmpty) {
                model.tracksPendingRemoval = tracks
            },
        ]
    }

    /// One track, right-clicked wherever tracks are listed. `remove` is the
    /// list's own way out — a playlist removes from itself, an album has none
    /// — and is a different, smaller thing than "Remove from Library" below
    /// it, which is why the two never share a group.
    static func track(_ track: Track,
                      model: AppModel,
                      play: @escaping () -> Void,
                      addToQueue: (() -> Void)? = nil,
                      remove: (title: String, action: () -> Void)? = nil) -> [MenuItem] {
        var items: [MenuItem] = [.action("Play", Symbol.play, play)]
        if let addToQueue {
            items.append(.action("Add to Queue", Symbol.addToQueue, addToQueue))
        }
        items.append(.separator)
        items.append(destinations(model: model, tracks: [track]))
        items.append(.separator)
        items.append(.action("Reveal in Finder", Symbol.revealInFinder) {
            NSWorkspace.shared.activateFileViewerSelecting([track.url])
        })
        items.append(.action("Get Info", Symbol.getInfo) {
            model.infoTrack = track
        })
        if let remove {
            items.append(.separator)
            items.append(.action(remove.title, Symbol.remove,
                                 shortcut: "⌫", destructive: true, remove.action))
        }
        items.append(.separator)
        items.append(.action("Remove from Library", Symbol.delete, destructive: true) {
            model.tracksPendingRemoval = [track]
        })
        return items
    }

    /// A track sitting in Up Next.
    static func queued(_ track: Track, playback: PlaybackController) -> [MenuItem] {
        [
            .action("Play Now", Symbol.play) { playback.jump(to: track) },
            .separator,
            .action("Remove from Queue", Symbol.remove,
                    shortcut: "⌫", destructive: true) {
                playback.removeFromUpNext(track)
            },
        ]
    }
}
