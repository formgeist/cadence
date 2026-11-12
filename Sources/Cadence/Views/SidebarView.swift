import SwiftUI
import UniformTypeIdentifiers
import OSLog
import CadenceCore
import CadenceLibrary

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @Environment(LibraryImporter.self) private var importer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(isPlaying: playback.isPlaying)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 22)

            SectionLabel("Library")
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            VStack(spacing: Tokens.Space.xxs) {
                ForEach(AppModel.Tab.allCases) { tab in
                    NavigationRow(tab: tab, isSelected: isSelected(tab)) {
                        model.show(.library)
                        model.tab = tab
                    }
                }
            }
            .padding(.horizontal, 10)

            PlaylistSection()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Tokens.Space.s) {
                    SectionLabel("Local library", size: 10, color: Color(hex: 0x4E4E57))
                    Spacer(minLength: 0)
                    if !importer.folders.isEmpty {
                        IconButton(systemImage: importer.isImporting ? "xmark" : "arrow.clockwise",
                                   label: importer.isImporting ? "Cancel Scan" : "Rescan Library",
                                   glyphSize: 9.5, side: 16) {
                            if importer.isImporting {
                                importer.cancel()
                            } else {
                                importer.rescanAll { Task { await model.load() } }
                            }
                        }
                    }
                }

                // Swapping the row's text in place — rather than sliding a
                // banner in above the content — is what keeps the sidebar and
                // everything to its right from jumping while a scan runs
                // (issue #56).
                Group {
                    if let progress = importer.progress {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(importSummary(progress))
                                .monospacedDigit()
                        }
                    } else {
                        Text(model.librarySummary)
                    }
                }
                .font(Tokens.Typography.mono(10.5))
                .foregroundStyle(Color(hex: 0x7D7D88))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(libraryAccessibilityLabel)
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(hex: 0x1C1C21)).frame(height: 1)
            }
        }
        .frame(width: Tokens.Layout.sidebarWidth)
        .background(Tokens.Palette.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Tokens.Palette.border).frame(width: 1)
        }
    }

    /// An artist screen keeps Artists lit, so the sidebar does not go blank
    /// the moment you drill in. A playlist screen does not light the Playlists
    /// row: the playlist's own row below is lit instead, and it says more.
    private func isSelected(_ tab: AppModel.Tab) -> Bool {
        switch model.screen {
        case .library: model.tab == tab
        case .artist: tab == .artists
        case .genre: tab == .genres
        case .catalog: tab == .catalogs
        case .album, .playlist, .likedSongs, .settings: false
        }
    }

    private func importSummary(_ progress: LibraryScanner.Progress) -> String {
        guard progress.found > 0 else { return "Scanning…" }
        return "\(progress.processed) / \(progress.found) tracks"
    }

    private var libraryAccessibilityLabel: String {
        guard let progress = importer.progress else {
            return "Local library: \(model.librarySummary)"
        }
        return "Local library: \(importSummary(progress))"
    }
}

private struct NavigationRow: View {
    var tab: AppModel.Tab
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                CadenceIcon(tab.icon, size: 13)
                    .frame(width: 16, height: 16)
                Text(tab.rawValue)
                    .font(Tokens.Typography.navItem)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected || isHovering
                             ? Color(hex: 0xF2F2F6) : Color(hex: 0x90909B))
            .padding(.horizontal, 10)
            .padding(.vertical, Tokens.Space.s)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .fill(isSelected
                          ? Tokens.Palette.navActive
                          : (isHovering ? Tokens.Palette.navHover : .clear))
            }
        }
        .plainControl()
        .animatedHover($isHovering)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The Playlists heading, its folders, and the playlists filed under none.
///
/// "Back to the top level" has three targets: the heading, the empty space
/// below the list, and the loose playlists themselves. A playlist dragged
/// over a loose playlist lights nothing. Lighting the row would say "into
/// this playlist", and lighting the heading, far above the pointer, read as
/// a stray highlight. Most of the time the dragged playlist is already loose
/// and is only being moved around among the others. None of these targets
/// wraps another — see `AppModel.handleDrop`.
private struct PlaylistSection: View {
    @Environment(AppModel.self) private var model

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Space.xxs) {
                SectionLabel("Playlists")
                Spacer(minLength: 0)
                IconButton(systemImage: PlaylistMenu.Symbol.newFolder, label: "New folder") {
                    model.naming = .createFolder
                }
                IconButton(systemImage: "plus", label: "New playlist") {
                    model.naming = .create(seed: [])
                }
            }
            .padding(.leading, 18)
            // The button's own 20pt box carries the rest of the inset, so the
            // glyph lines up with the rows' hover wash rather than the text.
            .padding(.trailing, 12)
            .padding(.top, Tokens.Space.xl)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .background {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                        .strokeBorder(Tokens.Palette.accent, lineWidth: 1)
                        .padding(.horizontal, 10)
                        .padding(.top, Tokens.Space.xl - 4)
                        .padding(.bottom, 2)
                }
            }
            // The heading is the top level's own row: dropping a playlist on
            // it takes it out of whatever folder it was in. Playlists only,
            // so it never lights for tracks it would refuse.
            .dropDestination(for: PlaylistMoveItem.self) { items, _ in
                items.first.map { model.handleDrop(.playlist($0.playlistID), on: .topLevel) }
                    ?? false
            } isTargeted: { isTargeted = $0 }

            // Always first and always there, even with nothing liked yet: it
            // is where the heart on a track row sends things, and an empty
            // one says how to fill it. Not in a folder and not draggable — it
            // is the library's own list, not one the user made.
            LikedSongsRow(isSelected: model.screen == .likedSongs)
                .padding(.horizontal, 10)
                .padding(.bottom, 1)

            if !model.playlists.isEmpty || !model.playlistFolders.isEmpty {
                // Folders first, then the loose playlists: the folders are
                // the structure, and a folder sandwiched between playlists
                // reads as one more playlist until you spot the chevron.
                VStack(spacing: 1) {
                    ForEach(model.playlistFolders) { folder in
                        FolderGroup(folder: folder)
                    }
                    ForEach(model.playlists(in: nil)) { playlist in
                        PlaylistRow(playlist: playlist,
                                    isSelected: model.screen == .playlist(playlist.id))
                    }
                }
                .padding(.horizontal, 10)
            }

            // The empty space under the list is a top-level target too: it
            // is the obvious place to let go of a playlist being pulled out
            // of a folder. A sibling of the rows, not a wrapper around them —
            // see `AppModel.handleDrop(_:on:)`.
            Color.clear
                .frame(maxWidth: .infinity, minHeight: Tokens.Space.l, maxHeight: .infinity)
                .contentShape(Rectangle())
                .overlay(alignment: .top) {
                    if isTailTargeted { insertionLine }
                }
                .dropDestination(for: PlaylistMoveItem.self) { items, _ in
                    items.first.map { model.handleDrop(.playlist($0.playlistID), on: .topLevel) }
                        ?? false
                } isTargeted: { isTailTargeted = $0 }
        }
    }

    @State private var isTailTargeted = false

    /// Where a playlist dropped below the list will land: after the last
    /// loose playlist, out of any folder.
    private var insertionLine: some View {
        Capsule()
            .fill(Tokens.Palette.accent)
            .frame(height: 2)
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .allowsHitTesting(false)
    }
}

/// A sidebar folder: a disclosure row, then its playlists while open.
///
/// The header takes a dropped playlist, and so does each row under it, so
/// letting go anywhere in an open folder files the playlist there. Whichever
/// of them the pointer is over, it is the folder that lights, as one
/// outline round the header and its rows: a playlist row never lights for
/// another playlist, because that playlist is not what it would land in.
///
/// The group draws that outline but is not itself a drop target. The rows
/// carry their own targets for tracks, and one target wrapped round another
/// is a fragile thing to rely on in SwiftUI.
private struct FolderGroup: View {
    @Environment(AppModel.self) private var model
    var folder: PlaylistFolder

    @State private var isHovering = false
    @State private var isHeaderTargeted = false
    @State private var isHintTargeted = false
    /// Member rows a dragged playlist is over. A count, not a flag, because
    /// moving from one row to the next can report the enter before the exit.
    @State private var memberRowHovers = 0

    private var isTargeted: Bool {
        isHeaderTargeted || isHintTargeted || memberRowHovers > 0
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) {
            model.setExpanded(!model.isExpanded(folder), folder)
        }
    }

    var body: some View {
        let members = model.playlists(in: folder.id)
        let isExpanded = model.isExpanded(folder)

        VStack(spacing: 1) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    // In the 18pt slot a playlist row gives its cover, so
                    // folder and playlist names start on the same line.
                    CadenceIcon(PlaylistMenu.Symbol.folder, size: 11.5)
                        .frame(width: 18, height: 18)
                    Text(folder.name)
                        .font(Tokens.Typography.sans(12.5, .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    CadenceIcon("chevron.right", size: 8)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Color(hex: 0x6E6E78))
                }
                .foregroundStyle(isHovering || isTargeted
                                 ? Color(hex: 0xEDEDF2) : Color(hex: 0x90909B))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                        .fill(isHovering || isTargeted ? Tokens.Palette.navHover : .clear)
                }
                .contentShape(Rectangle())
            }
            .plainControl()
            .animatedHover($isHovering)
            // Playlists only: a folder holds no tracks, so it should not
            // light up for them.
            .dropDestination(for: PlaylistMoveItem.self) { items, _ in
                items.first.map { model.handleDrop(.playlist($0.playlistID), on: .folder(folder.id)) }
                    ?? false
            } isTargeted: { isHeaderTargeted = $0 }
            .cadenceContextMenu {
                PlaylistMenu.folder(folder, model: model)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Folder: \(folder.name), "
                + (members.count == 1 ? "1 playlist" : "\(members.count) playlists"))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses the folder." : "Expands the folder.")
            .accessibilityAddTraits(.isButton)
            // `.ignore` above replaces the button with a new element, and
            // the button's own press does not come with it: without this,
            // VoiceOver's press — and AXPress — do nothing.
            .accessibilityAction(.default, toggle)

            if isExpanded {
                if members.isEmpty {
                    // Says what the folder is for, rather than leaving an
                    // open folder that looks like it failed to load.
                    Text("Drag playlists here")
                        .font(Tokens.Typography.sans(11.5, .medium))
                        .foregroundStyle(isTargeted
                                         ? Tokens.Palette.accent : Color(hex: 0x55555F))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 38)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        // It says "here", so here has to work.
                        .dropDestination(for: PlaylistMoveItem.self) { items, _ in
                            items.first.map {
                                model.handleDrop(.playlist($0.playlistID), on: .folder(folder.id))
                            } ?? false
                        } isTargeted: { isHintTargeted = $0 }
                } else {
                    ForEach(members) { playlist in
                        PlaylistRow(playlist: playlist,
                                    isSelected: model.screen == .playlist(playlist.id)) {
                            memberRowHovers = max(0, memberRowHovers + ($0 ? 1 : -1))
                        }
                        .padding(.leading, Tokens.Space.l)
                    }
                }
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .strokeBorder(Tokens.Palette.accent, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Liked Songs in the sidebar. Shaped like a playlist row, with a heart where
/// the cover goes. Tracks dropped on it are liked, the way tracks dropped on a
/// playlist are added to it.
private struct LikedSongsRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var isSelected: Bool

    @State private var isHovering = false
    @State private var isTargeted = false

    private var isLit: Bool { isSelected || isHovering || isTargeted }

    var body: some View {
        Button { model.show(.likedSongs) } label: {
            HStack(spacing: 10) {
                LikedSongsBadge(side: 18, glyphSize: 8.5)
                Text(AppModel.likedSongsName)
                    .font(Tokens.Typography.sans(12.5, .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isLit ? Color(hex: 0xEDEDF2) : Color(hex: 0x90909B))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .fill(isSelected ? Tokens.Palette.navActive
                          : (isHovering || isTargeted ? Tokens.Palette.navHover : .clear))
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                        .strokeBorder(Tokens.Palette.accent, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .plainControl()
        .animatedHover($isHovering)
        .dropDestination(for: TrackSelection.self) { selections, _ in
            let tracks = selections.flatMap(\.trackIDs).compactMap { model.track(id: $0) }
            guard !tracks.isEmpty else { return false }
            Task { await model.setLiked(true, tracks, announce: true) }
            return true
        } isTargeted: { isTargeted = $0 }
        .cadenceContextMenu {
            PlaylistMenu.likedSongs(model: model, playback: playback)
        }
        .accessibilityLabel("\(AppModel.likedSongsName), \(model.likedSongsSummary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A heart on an accent tile — what Liked Songs shows where a playlist shows
/// its covers, in the sidebar and as its page's header art.
struct LikedSongsBadge: View {
    var side: CGFloat
    var glyphSize: CGFloat
    var cornerRadius: CGFloat = Tokens.Radius.thumb

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Tokens.Palette.accent, Color(hex: 0x8E2A36)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            CadenceIcon("heart.fill", size: glyphSize)
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// A playlist in the sidebar: the way in, and the place tracks are dropped.
private struct PlaylistRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var playlist: Playlist
    var isSelected: Bool
    /// Told when a dragged playlist (not tracks) comes over or leaves this
    /// row, so the folder or the top level it would land in can light
    /// instead of the row.
    var onPlaylistHover: (Bool) -> Void = { _ in }

    @State private var isHovering = false
    /// Highlighted while tracks are dragged over, so the row you are about to
    /// drop on is unambiguous in a stack of five that look alike. Never for a
    /// dragged playlist — see `onPlaylistHover`.
    @State private var isTargeted = false
    /// Which side of this row a dragged playlist would land on, drawn as an
    /// insertion line there. Nil when no playlist is over the row.
    @State private var insertion: AppModel.PlaylistPlacement?
    /// Where the pointer is and how big the row is, so the drag chip can sit
    /// under the pointer — see `TrackDragPreview.anchored(in:at:)`.
    @State private var pointer: CGPoint = .zero
    @State private var rowSize: CGSize = .zero

    private var isLit: Bool { isSelected || isHovering || isTargeted }

    /// Not a `Button`. A `.draggable` on a button never lifts: the button
    /// keeps the press for itself and the drag is never handed over. The
    /// album cards have the same problem. The rows that do drag (album and
    /// playlist track rows) are plain views with a tap gesture, so this is
    /// one too.
    var body: some View {
        HStack(spacing: 10) {
            CoverMosaic(artworkIDs: model.coverIDs(forPlaylist: playlist),
                        cornerRadius: Tokens.Radius.thumb, stripe: 4, displaySize: 32)
                .frame(width: 18, height: 18)
            Text(playlist.name)
                .font(Tokens.Typography.sans(12.5, .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isLit ? Color(hex: 0xEDEDF2) : Color(hex: 0x90909B))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                .fill(background)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .strokeBorder(Tokens.Palette.accent, lineWidth: 1)
            }
        }
        .overlay(alignment: insertion == .after ? .bottom : .top) {
            if insertion != nil {
                Capsule()
                    .fill(Tokens.Palette.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    // Into the 1pt gap between rows, so the line sits between
                    // two playlists rather than on one of them.
                    .offset(y: insertion == .after ? 1.5 : -1.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .animatedHover($isHovering)
        .pointingHandCursor()
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { rowSize = geometry.size }
                    .onChange(of: geometry.size) { _, new in rowSize = new }
            }
        }
        .onContinuousHover { phase in
            if case .active(let point) = phase { pointer = point }
        }
        // A playlist drags as a `PlaylistMoveItem`, never as its tracks, so a
        // playlist landing on another is a move, not "add all of these".
        // Anchored like the album rows' chip: the row is far smaller than the
        // chip, and an unanchored one is clipped to a sliver.
        .draggable(PlaylistMoveItem(playlistID: playlist.id)) {
            TrackDragPreview(systemImage: "music.note.list",
                             title: playlist.name, detail: playlist.summary)
                .anchored(in: rowSize, at: pointer)
        }
        // After `.draggable`, the order the track rows use.
        .onTapGesture { model.show(.playlist(playlist.id)) }
        // Tracks are added; another playlist joins this one's folder. One
        // target for both — see `AppModel.handleDrop(_:on:)` — through a
        // delegate rather than `dropDestination`, because only a delegate
        // learns which of the two is hovering before it is dropped.
        .onDrop(of: [.cadenceTracks, .cadencePlaylistMove],
                delegate: PlaylistRowDropDelegate(model: model, playlist: playlist,
                                                  isTrackTargeted: $isTargeted,
                                                  insertion: $insertion,
                                                  rowHeight: rowSize.height,
                                                  onPlaylistHover: onPlaylistHover))
        .cadenceContextMenu {
            PlaylistMenu.actions(model: model, playback: playback, playlist: playlist)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playlist: \(playlist.name), \(playlist.summary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // With no button underneath, this is what VoiceOver's press (and
        // AXPress) runs.
        .accessibilityAction(.default) { model.show(.playlist(playlist.id)) }
    }

    private var background: Color {
        if isSelected { return Tokens.Palette.navActive }
        return isHovering || isTargeted ? Tokens.Palette.navHover : .clear
    }

}

/// A sidebar playlist row's drop handling, for both payloads it takes.
///
/// Tracks light the row: they land in this playlist. A dragged playlist does
/// not: it lands in this row's folder (or the top level), so the hover is
/// reported upwards through `onPlaylistHover` and the folder lights instead.
/// The row only shows an insertion line above or below itself — the top
/// half of the row puts the playlist before it, the bottom half after.
private struct PlaylistRowDropDelegate: DropDelegate {
    let model: AppModel
    let playlist: Playlist
    @Binding var isTrackTargeted: Bool
    @Binding var insertion: AppModel.PlaylistPlacement?
    let rowHeight: CGFloat
    let onPlaylistHover: (Bool) -> Void

    private func placement(_ info: DropInfo) -> AppModel.PlaylistPlacement {
        info.location.y < rowHeight / 2 ? .before : .after
    }

    private func carriesPlaylist(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.cadencePlaylistMove])
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.cadenceTracks, .cadencePlaylistMove])
    }

    func dropEntered(info: DropInfo) {
        if carriesPlaylist(info) {
            onPlaylistHover(true)
            insertion = placement(info)
        } else {
            isTrackTargeted = true
        }
    }

    func dropExited(info: DropInfo) {
        if carriesPlaylist(info) {
            onPlaylistHover(false)
            insertion = nil
        } else {
            isTrackTargeted = false
        }
    }

    /// Move for a playlist, copy for tracks: the cursor badge says which is
    /// about to happen.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard carriesPlaylist(info) else { return DropProposal(operation: .copy) }
        let side = placement(info)
        if insertion != side { insertion = side }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let side = placement(info)
        // Not every drop is followed by an exit, and a count left at one
        // would keep the folder lit after the drag is over.
        dropExited(info: info)

        // Each provider is asked what it actually carries rather than trusted
        // to match the type it was looked up by: a tracks provider decoded
        // as a playlist (or the reverse) fails, and a failed decode is a drop
        // that silently adds nothing.
        var handled = false
        for provider in info.itemProviders(for: [.cadencePlaylistMove, .cadenceTracks]) {
            if provider.hasItemConformingToTypeIdentifier(UTType.cadencePlaylistMove.identifier) {
                handled = true
                _ = provider.loadTransferable(type: PlaylistMoveItem.self) { result in
                    switch result {
                    case .success(let item):
                        Self.log.debug("Playlist drop decoded onto \(playlist.name, privacy: .public)")
                        Task { @MainActor in
                            model.handleDrop(.playlist(item.playlistID),
                                             on: .playlist(playlist, placement: side))
                        }
                    case .failure(let error):
                        Self.log.error("Playlist drop failed to decode: \(error, privacy: .public)")
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.cadenceTracks.identifier) {
                handled = true
                _ = provider.loadTransferable(type: TrackSelection.self) { result in
                    switch result {
                    case .success(let selection):
                        Self.log.debug(
                            "Track drop decoded: \(selection.trackIDs.count) ids onto \(playlist.name, privacy: .public)")
                        Task { @MainActor in
                            model.handleDrop(.tracks(selection.trackIDs), on: .playlist(playlist))
                        }
                    case .failure(let error):
                        Self.log.error("Track drop failed to decode: \(error, privacy: .public)")
                    }
                }
            } else {
                Self.log.error("""
                    Sidebar drop with no usable type: \
                    \(provider.registeredTypeIdentifiers, privacy: .public)
                    """)
            }
        }
        return handled
    }

    /// Drops fail without a word in the UI, so the reason goes to the
    /// unified log (`log show --predicate 'subsystem == "com.formgeist.cadence"'`).
    private static let log = Logger(subsystem: "com.formgeist.cadence", category: "SidebarDrop")
}
