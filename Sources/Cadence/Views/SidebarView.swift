import SwiftUI
import CadenceCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

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

            SectionLabel("Playlists")
                .padding(.horizontal, 18)
                .padding(.top, Tokens.Space.xxl)
                .padding(.bottom, 6)

            VStack(spacing: 1) {
                ForEach(model.playlists) { playlist in
                    PlaylistRow(playlist: playlist)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: Tokens.Space.l)

            VStack(alignment: .leading, spacing: 5) {
                SectionLabel("Local library", size: 10, color: Color(hex: 0x4E4E57))
                Text(model.librarySummary)
                    .font(Tokens.Typography.mono(10.5))
                    .foregroundStyle(Color(hex: 0x7D7D88))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Local library: \(model.librarySummary)")
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

    /// An album screen keeps its parent tab lit, so the sidebar never goes
    /// blank when you drill in.
    private func isSelected(_ tab: AppModel.Tab) -> Bool {
        model.screen == .library && model.tab == tab
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

private struct PlaylistRow: View {
    var playlist: Playlist
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(artworkID: nil, cornerRadius: Tokens.Radius.thumb,
                        stripe: 4, displaySize: 32)
                .frame(width: 18, height: 18)
            Text(playlist.name)
                .font(Tokens.Typography.sans(12.5, .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isHovering ? Color(hex: 0xEDEDF2) : Color(hex: 0x90909B))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                .fill(isHovering ? Tokens.Palette.navHover : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playlist: \(playlist.name)")
    }
}
