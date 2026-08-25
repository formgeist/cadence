import SwiftUI
import CadenceCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @Environment(LibraryImporter.self) private var importer

    var body: some View {
        @Bindable var model = model

        return ZStack {
            VStack(spacing: 0) {
                // The search suggestions hang out of the header's bounds, and
                // a VStack paints its children in order — so without this the
                // library draws straight over them (issue #21).
                TitleBarView()
                    .zIndex(50)
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
        // The header *is* the title bar — see `WindowChrome`. Without this
        // SwiftUI insets the whole window by the title bar's height and the
        // header lands in a second band below the traffic lights, which is
        // issue #15 exactly.
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeInOut(duration: 0.2), value: model.isImmersive)
        .animation(.easeOut(duration: 0.2), value: playback.notice)
        .animation(.easeOut(duration: 0.2), value: model.actionError)
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .task {
            await model.load()
            // A library that already has folders rescans on launch, so files
            // added since last time appear without being asked for — but not
            // a folder whose last scan is still recent (issue #39), and not
            // before the window has actually had a chance to paint. Racing
            // the scan against the first frame is what made launch feel slow
            // in the first place.
            guard !importer.folders.isEmpty, !model.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            importer.rescanStaleFolders { Task { await model.load() } }
        }
        .overlay(alignment: .bottom) { errorBanner }
        .sheet(item: $model.naming) { naming in
            // A sheet is its own window; the model has to be handed across.
            PlaylistNameSheet(naming: naming)
                .environment(model)
        }
        .sheet(item: $model.infoTrack) { track in
            TrackInfoSheet(track: track)
        }
        .confirmationDialog(
            deletionPrompt,
            isPresented: Binding(get: { model.playlistPendingDeletion != nil },
                                 set: { if !$0 { model.playlistPendingDeletion = nil } }),
            presenting: model.playlistPendingDeletion
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                model.playlistPendingDeletion = nil
                Task { await model.deletePlaylist(playlist) }
            }
            Button("Cancel", role: .cancel) { model.playlistPendingDeletion = nil }
        } message: { _ in
            // Worth saying plainly: people expect deleting a playlist to be
            // the dangerous kind of delete.
            Text("The tracks stay in your library.")
        }
        .confirmationDialog(
            libraryRemovalPrompt,
            isPresented: Binding(get: { model.tracksPendingRemoval != nil },
                                 set: { if !$0 { model.tracksPendingRemoval = nil } }),
            presenting: model.tracksPendingRemoval
        ) { tracks in
            Button("Remove from Library", role: .destructive) {
                model.tracksPendingRemoval = nil
                Task { await model.removeFromLibrary(tracks) }
            }
            Button("Cancel", role: .cancel) { model.tracksPendingRemoval = nil }
        } message: { tracks in
            // The file staying put is the surprising half; the playlist
            // cascade (README-documented) is the half people forget to ask
            // about before they click through.
            Text(tracks.count == 1
                 ? "The file stays on disk. It’s also removed from any playlists it’s in."
                 : "The files stay on disk. They’re also removed from any playlists they’re in.")
        }
    }

    private var deletionPrompt: String {
        guard let playlist = model.playlistPendingDeletion else { return "Delete playlist?" }
        return "Delete “\(playlist.name)”?"
    }

    private var libraryRemovalPrompt: String {
        guard let tracks = model.tracksPendingRemoval, let first = tracks.first else {
            return "Remove from library?"
        }
        // A single track names itself; a whole album's worth names the
        // record, not "12 tracks", which says nothing about what is leaving.
        return tracks.count == 1
            ? "Remove “\(first.title)” from your library?"
            : "Remove “\(first.albumTitle)” from your library?"
    }

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            EmptyLibraryView()
        } else {
            libraryContent
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch model.screen {
        case .library:
            LibraryView()
        case .album(let key):
            if let album = model.album(for: key) {
                AlbumDetailView(album: album)
            } else {
                missing("That album is no longer in your library")
            }
        case .artist(let name):
            if let artist = model.artist(named: name) {
                ArtistDetailView(artist: artist)
            } else {
                missing("That artist is no longer in your library")
            }
        case .playlist(let id):
            if let playlist = model.playlist(id: id) {
                PlaylistDetailView(playlist: playlist)
            } else {
                missing("That playlist has been deleted")
            }
        }
    }

    /// A record can vanish under you — a rescan drops the folder, the file
    /// moves. Better a stated dead end than an empty pane.
    private func missing(_ message: String) -> some View {
        VStack(spacing: Tokens.Space.m) {
            Text(message)
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
        if let failure = model.actionError {
            Banner(text: failure,
                   icon: "exclamationmark.triangle.fill",
                   tint: Tokens.Palette.accent) {
                model.actionError = nil
            }
        } else if let added = model.notice {
            Banner(text: added, icon: "checkmark.circle.fill",
                   tint: Tokens.Palette.accent) {
                model.notice = nil
            }
        } else if let notice = playback.notice {
            Banner(text: notice, icon: "headphones", tint: Tokens.Palette.textSecondary) {
                playback.clearNotice()
            }
        } else if let error = playback.lastError {
            Banner(text: error.message,
                   icon: "exclamationmark.triangle.fill",
                   tint: Tokens.Palette.accent)
        }
    }
}

/// The one transient message surface. Errors and notices differ only in tint,
/// so they share a shape rather than drifting apart.
private struct Banner: View {
    var text: String
    var icon: String
    var tint: Color
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Tokens.Palette.textMuted)
                }
                .plainControl()
            }
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.m)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .fill(Tokens.Palette.popover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .padding(.bottom, 28)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
