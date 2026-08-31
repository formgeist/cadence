import SwiftUI
import CadenceCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @Environment(LibraryImporter.self) private var importer
    /// Opens the Settings scene — the same window ⌘, reaches. Present but inert
    /// in the snapshot and a11y harnesses, which host this view without an app
    /// scene.
    @Environment(\.openSettings) private var openSettings

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
                    // Nothing to show and nothing coming up — an empty pane
                    // just narrows the library for no reason (issue #75).
                    if hasNowPlayingContent {
                        NowPlayingPane()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
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
        .animation(.easeInOut(duration: 0.2), value: hasNowPlayingContent)
        .animation(.easeOut(duration: 0.2), value: playback.notice)
        .animation(.easeOut(duration: 0.2), value: model.actionError)
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .animation(.easeOut(duration: 0.2), value: importer.notice)
        .task {
            await model.load()
            // The queue only has ids until the library backing them exists —
            // see #42.
            playback.restoreQueue { model.track(id: $0) }
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
        .sheet(item: $model.editingArtist) { artist in
            ArtistImageSheet(artist: artist)
                .environment(model)
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

    /// Whether the Now Playing pane has anything to show — something playing,
    /// or something queued up behind it.
    private var hasNowPlayingContent: Bool {
        playback.currentTrack != nil || !playback.upNext.isEmpty
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
        // Preferences is reachable even before a note of music has been added,
        // so the empty-library placeholder gives way to it.
        if model.isEmpty && model.screen != .settings {
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
        case .settings:
            SettingsView()
        case .album(let key):
            if let album = model.album(for: key) {
                AlbumDetailView(album: album)
            } else if model.isInitialLoading {
                SkeletonAlbumDetail()
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
            // No timer: a failure is the case a silent disappearance hurts, so
            // it stays until the user has read it and dismissed it.
            Banner(text: failure,
                   icon: "exclamationmark.triangle.fill",
                   tint: Tokens.Palette.accent) {
                model.actionError = nil
            }
        } else if let added = model.notice {
            Banner(text: added, icon: "checkmark.circle.fill",
                   tint: Tokens.Palette.accent,
                   autoDismissAfter: Banner.noticeLifetime) {
                model.notice = nil
            }
        } else if let notice = playback.notice {
            // An output-device change leaves playback paused until the user acts,
            // so that notice stays put; a skipped track is just informational.
            Banner(text: notice, icon: "headphones", tint: Tokens.Palette.textSecondary,
                   autoDismissAfter: playback.noticeIsSticky ? nil : Banner.noticeLifetime) {
                playback.clearNotice()
            }
        } else if let error = playback.lastError {
            Banner(text: error.message,
                   icon: "exclamationmark.triangle.fill",
                   tint: Tokens.Palette.accent)
        } else if let scan = importer.notice {
            // A scan that couldn't read some files. The tracks it did add are
            // in the library already; this is the part that would otherwise
            // pass silently. No timer when there's something to go and look
            // at: the file list lives in Preferences, and "Review" opens it.
            Banner(text: scan, icon: "exclamationmark.triangle.fill",
                   tint: Tokens.Palette.accent,
                   autoDismissAfter: importer.scanFailures.isEmpty
                       ? Banner.noticeLifetime : nil,
                   actionLabel: importer.scanFailures.isEmpty ? nil : "Review",
                   action: { openSettings() },
                   onDismiss: { importer.clearNotice() })
        }
    }
}

/// The one transient message surface. Errors and notices differ only in tint,
/// so they share a shape rather than drifting apart.
private struct Banner: View {
    var text: String
    var icon: String
    var tint: Color
    /// When set — and the banner is dismissible — the banner dismisses itself
    /// after this long, with a border drawing clockwise around the container
    /// over the window so the countdown is visible. Nil leaves it up until
    /// dismissed.
    var autoDismissAfter: Duration?
    /// An optional call to action, shown as a text button before the dismiss
    /// control — e.g. "Review" to open the Preferences list behind a scan
    /// warning.
    var actionLabel: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// How long a success notice sits before it clears itself. Long enough to
    /// read a sentence, short enough not to linger over the library.
    static let noticeLifetime: Duration = .seconds(5)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much of the border has been drawn, 0 → 1. Reaching 1 dismisses.
    @State private var progress: Double = 0
    /// The pointer resting on the banner freezes the countdown, so a message
    /// can't slip away mid-read.
    @State private var isHovering = false

    private var countsDown: Bool { autoDismissAfter != nil && onDismiss != nil }

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(Tokens.Typography.sans(11.5, .bold))
                        .foregroundStyle(tint)
                }
                .plainControl()
            }
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
        .overlay {
            // The countdown, drawn as the border filling in clockwise from the
            // top. Reduce Motion drops it — the timer still fires.
            if countsDown && !reduceMotion {
                ClockwiseBorder(cornerRadius: Tokens.Radius.popover)
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(0.75)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .padding(.bottom, 28)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onHover { isHovering = $0 }
        // Keyed on `text`: a new message rebuilds the task and the countdown
        // restarts from empty.
        .task(id: text) {
            guard countsDown, let total = autoDismissAfter, let onDismiss else { return }
            let totalSeconds = total.seconds
            let tick = 0.05
            progress = 0
            var elapsed = 0.0
            while elapsed < totalSeconds {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if isHovering { continue }
                elapsed += tick
                // Linear over the tick so the border grows smoothly.
                withAnimation(.linear(duration: tick)) {
                    progress = min(1, elapsed / totalSeconds)
                }
            }
            onDismiss()
        }
    }
}

private extension Duration {
    /// The whole span in seconds, attoseconds folded back in.
    var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }
}

/// A rounded-rectangle outline traced clockwise from the top centre, so
/// `.trim(from: 0, to:)` fills it the way a clock hand sweeps. `RoundedRectangle`
/// starts its own path in a corner and runs the other way, which is why this
/// exists.
private struct ClockwiseBorder: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}
