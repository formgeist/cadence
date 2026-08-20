import SwiftUI
import CadenceCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TitleBarView()
                HStack(spacing: 0) {
                    SidebarView()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    NowPlayingPane()
                }
            }

            if model.isImmersive {
                ImmersiveView()
                    .zIndex(60)
            }
        }
        .background(Tokens.Palette.surface)
        .animation(.easeInOut(duration: 0.2), value: model.isImmersive)
        .task { await model.load() }
        .overlay(alignment: .bottom) { errorBanner }
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .library:
            LibraryView()
        case .album(let key):
            if let album = model.album(for: key) {
                AlbumDetailView(album: album)
            } else {
                missingAlbum
            }
        }
    }

    /// An album can vanish under you — a rescan drops the folder, the file
    /// moves. Better a stated dead end than an empty pane.
    private var missingAlbum: some View {
        VStack(spacing: Tokens.Space.m) {
            Text("That album is no longer in your library")
                .font(Tokens.Typography.sans(14, .semibold))
                .foregroundStyle(Tokens.Palette.textSecondary)
            Button("Back to library") { model.show(.library) }
                .plainControl()
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.surface)
    }

    /// Playback failures are reported, not swallowed — PLAN.md §7 lists the
    /// ways a file goes missing under a player that assumed it wouldn't.
    @ViewBuilder
    private var errorBanner: some View {
        if let error = playback.lastError {
            HStack(spacing: Tokens.Space.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokens.Palette.accent)
                Text(error.message)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Tokens.Space.l)
            .padding(.vertical, Tokens.Space.m)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                    .fill(Tokens.Palette.popover)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                    .strokeBorder(Tokens.Palette.accentEdge, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
