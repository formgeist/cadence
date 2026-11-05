import SwiftUI
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
        case .album, .playlist, .settings: false
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
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The Playlists heading, its folders, and the playlists filed under none.
///
/// The whole section, down to the library footer, is the drop target for
/// "back to the top level". A folder takes a playlist dropped on it; anywhere
/// else in here takes it out of whatever folder it was in. A strip of its own
/// for that would be one more thing to aim at, and an easy one to miss.
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

            if model.playlists.isEmpty && model.playlistFolders.isEmpty {
                Text("Nothing yet")
                    .font(Tokens.Typography.sans(11.5, .medium))
                    .foregroundStyle(Color(hex: 0x55555F))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 2)
            } else {
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

            Spacer(minLength: Tokens.Space.l)
        }
        .contentShape(Rectangle())
        .dropDestination(for: PlaylistMoveItem.self) { items, _ in
            guard let item = items.first else { return false }
            Task { await model.movePlaylist(item.playlistID, toFolder: nil) }
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            // Fainter than a folder's outline: this is the fallback target,
            // and it should not compete with the folder you are aiming for.
            if isTargeted {
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .strokeBorder(Tokens.Palette.accent.opacity(0.5), lineWidth: 1)
                    .padding(.horizontal, 6)
                    .padding(.bottom, Tokens.Space.s)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A sidebar folder: a disclosure row, then its playlists while open.
///
/// The whole group — header and the rows under it — takes a dropped
/// playlist, so letting go anywhere among a folder's playlists files the new
/// one beside them rather than out at the top level.
private struct FolderGroup: View {
    @Environment(AppModel.self) private var model
    var folder: PlaylistFolder

    @State private var isHovering = false
    @State private var isTargeted = false

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
            .onHover { isHovering = $0 }
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
                        .foregroundStyle(Color(hex: 0x55555F))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 38)
                        .padding(.vertical, 5)
                } else {
                    ForEach(members) { playlist in
                        PlaylistRow(playlist: playlist,
                                    isSelected: model.screen == .playlist(playlist.id))
                            .padding(.leading, Tokens.Space.l)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: PlaylistMoveItem.self) { items, _ in
            guard let item = items.first else { return false }
            Task { await model.movePlaylist(item.playlistID, toFolder: folder.id) }
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .strokeBorder(Tokens.Palette.accent, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A playlist in the sidebar: the way in, and the place tracks are dropped.
private struct PlaylistRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var playlist: Playlist
    var isSelected: Bool

    @State private var isHovering = false
    /// Highlighted while a drag hovers, so the row you are about to drop on is
    /// unambiguous in a stack of five that look alike.
    @State private var isTargeted = false

    private var isLit: Bool { isSelected || isHovering || isTargeted }

    var body: some View {
        Button { model.show(.playlist(playlist.id)) } label: {
            HStack(spacing: 10) {
                ArtworkView(artworkID: artworkID, cornerRadius: Tokens.Radius.thumb,
                            stripe: 4, displaySize: 32)
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
            .contentShape(Rectangle())
        }
        .plainControl()
        .onHover { isHovering = $0 }
        // A playlist drags as a `PlaylistMoveItem`, never as its tracks, so
        // this row's own track drop below cannot mistake one playlist landing
        // on another for "add all of these".
        .draggable(PlaylistMoveItem(playlistID: playlist.id)) {
            TrackDragPreview(systemImage: "music.note.list",
                             title: playlist.name, detail: playlist.summary)
        }
        .dropDestination(for: TrackSelection.self) { selections, _ in
            let ids = selections.flatMap(\.trackIDs)
            guard !ids.isEmpty else { return false }
            Task { await model.addTracks(ids, to: playlist.id) }
            return true
        } isTargeted: { isTargeted = $0 }
        .cadenceContextMenu {
            PlaylistMenu.actions(model: model, playback: playback, playlist: playlist)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playlist: \(playlist.name), \(playlist.summary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // Same reason as the folder row: `.ignore` drops the button's press.
        .accessibilityAction(.default) { model.show(.playlist(playlist.id)) }
    }

    private var background: Color {
        if isSelected { return Tokens.Palette.navActive }
        return isHovering || isTargeted ? Tokens.Palette.navHover : .clear
    }

    /// The first cover in the playlist, so a full one is recognisable at a
    /// glance rather than being one of five identical placeholders. Lazy so a
    /// long playlist stops at that first hit instead of resolving every id on
    /// every body pass. See #86.
    private var artworkID: Artwork.ID? {
        playlist.trackIDs.lazy.compactMap { model.track(id: $0)?.artworkID }.first
    }
}
