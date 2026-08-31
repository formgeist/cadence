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

            HStack(spacing: Tokens.Space.s) {
                SectionLabel("Playlists")
                Spacer(minLength: 0)
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

            if model.playlists.isEmpty {
                Text("Nothing yet")
                    .font(Tokens.Typography.sans(11.5, .medium))
                    .foregroundStyle(Color(hex: 0x55555F))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 1) {
                    ForEach(model.playlists) { playlist in
                        PlaylistRow(playlist: playlist,
                                    isSelected: model.screen == .playlist(playlist.id))
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: Tokens.Space.l)

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
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .regular))
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
