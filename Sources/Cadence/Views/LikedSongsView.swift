import SwiftUI
import CadenceCore

/// Liked Songs, open: every track with its heart filled, most recently liked
/// first. `PlaylistDetailView`'s shape — a header over a list — without the
/// parts that make a playlist the user's own: there is nothing to rename,
/// reorder or delete, because the hearts decide what is in it and the order
/// is the order they were given.
struct LikedSongsView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    /// The row a single click put under the cursor; playing needs a second
    /// click, as everywhere else.
    @State private var selectedTrackID: Track.ID?

    private func isLoaded(_ tracks: [Track]) -> Bool {
        guard let id = playback.currentTrack?.id else { return false }
        return tracks.contains { $0.id == id }
    }

    var body: some View {
        // Resolved once per render and handed down, as `PlaylistDetailView`
        // does with its entries.
        let tracks = model.likedTracks

        VStack(spacing: 0) {
            header(tracks: tracks)
            if tracks.isEmpty {
                emptyState
            } else {
                trackList(tracks)
            }
        }
        .background(Tokens.Palette.surface)
    }

    // MARK: Header

    private func header(tracks: [Track]) -> some View {
        HStack(alignment: .bottom, spacing: 32) {
            LikedSongsBadge(side: Tokens.Layout.artistHeaderArt, glyphSize: 46,
                            cornerRadius: Tokens.Radius.card)
                .shadow(color: .black.opacity(0.55), radius: 25, y: 12)

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Smart playlist", color: Tokens.Palette.accent)

                Text(AppModel.likedSongsName)
                    .font(Tokens.Typography.sans(38, .heavy))
                    .tracking(Tokens.Typography.Tracking.display)
                    .foregroundStyle(Color(hex: 0xF4F4F8))
                    .lineLimit(1)

                Text(summary(tracks))
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundStyle(Color(hex: 0x82828D))

                HStack(spacing: 10) {
                    PlayPauseButton(isPlaying: isLoaded(tracks) && playback.isPlaying,
                                    subject: AppModel.likedSongsName) {
                        if isLoaded(tracks) {
                            playback.togglePlayPause()
                        } else if let first = tracks.first {
                            playback.play(first, in: tracks)
                        }
                    }
                    .disabled(tracks.isEmpty)

                    CapsuleButton(title: "Shuffle") { playback.shuffle(tracks) }
                        .disabled(tracks.isEmpty)

                    CapsuleButton(systemImage: "plus",
                                  accessibilityLabel: "Add \(AppModel.likedSongsName) to queue") {
                        playback.appendToQueue(tracks)
                    }
                    .disabled(tracks.isEmpty)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Tokens.Space.contentInset)
        .padding(.top, 34)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [Tokens.Palette.immersiveTop, Tokens.Palette.surface],
                startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.Palette.border).frame(height: 1)
        }
    }

    /// `12 tracks · 47 min`.
    private func summary(_ tracks: [Track]) -> String {
        let total = tracks.reduce(0) { $0 + $1.duration }
        return "\(model.likedSongsSummary) · \(DurationFormat.approximate(total))"
    }

    // MARK: Tracks

    private var emptyState: some View {
        EmptyState(
            systemImage: "heart",
            title: "No liked songs yet",
            message: "Click the heart beside any track on an album,\n"
                + "or press ⌘L while a song plays, and it lands here."
        ) {
            EmptyView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func trackList(_ tracks: [Track]) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    LikedSongsListItem(track: track, position: index, tracks: tracks,
                                       selectedTrackID: $selectedTrackID)
                }
            }
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.m)
        }
        .scrollContentBackground(.hidden)
    }
}

/// One row of Liked Songs with everything that hangs off it — dragging out to
/// a playlist, clicks, the menu and the rotor. Its own view so the list's
/// body stays small enough for the type checker.
private struct LikedSongsListItem: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var track: Track
    var position: Int
    /// The whole list, in order — what playing a row queues.
    var tracks: [Track]
    @Binding var selectedTrackID: Track.ID?

    private var isCurrent: Bool { playback.currentTrack?.id == track.id }
    private var isSelected: Bool { selectedTrackID == track.id }

    var body: some View {
        row
            .cadenceContextMenu(onOpen: { selectedTrackID = track.id }) {
                // The like toggle in the shared track menu is this list's own
                // "remove", so no second one is passed.
                PlaylistMenu.track(track, model: model, play: play,
                                   addToQueue: { playback.appendToQueue([track]) })
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
            .accessibilityHint("Plays this track")
            .accessibilityAddTraits(isCurrent || isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, play)
            .accessibilityAction(named: Text("Remove from \(AppModel.likedSongsName)"), unlike)
            .accessibilityAction(named: Text("Go to artist"), goToArtist)
            .accessibilityAction(named: Text("Go to album"), goToAlbum)
    }

    private var row: some View {
        LikedTrackRow(track: track, position: position, isCurrent: isCurrent,
                      isPlaying: playback.isPlaying, isSelected: isSelected,
                      onToggle: toggle)
            .contentShape(Rectangle())
            // Out to a playlist in the sidebar, the same as any track row.
            // Nothing to reorder within: the order is the dates.
            .draggable(TrackSelection([track.id])) {
                TrackDragPreview.track(track)
            }
            .onTapGesture(count: 2, perform: play)
            .onTapGesture { selectedTrackID = track.id }
            .pointingHandCursor()
    }

    /// In Liked Songs' own order, so playing row 3 carries on down the list
    /// rather than into the album that track came from.
    private func play() {
        selectedTrackID = track.id
        playback.play(track, in: tracks)
    }

    private func toggle() {
        if isCurrent {
            selectedTrackID = track.id
            playback.togglePlayPause()
        } else {
            play()
        }
    }

    private func unlike() { Task { await model.setLiked(false, [track]) } }
    private func goToArtist() { model.show(.artist(track.artist)) }
    private func goToAlbum() { model.show(.album(track.albumKey)) }

    private var spokenLabel: String {
        var parts = ["\(position + 1)", track.title, track.artist, track.albumTitle]
        parts.append(NowPlayingPane.spokenDuration(track.duration))
        if isCurrent { parts.append("Now playing") }
        return parts.joined(separator: ", ")
    }
}

/// One liked track: the playlist row's columns, with the heart in front of
/// the time so unliking is one click from where you are looking.
private struct LikedTrackRow: View {
    @Environment(AppModel.self) private var model

    var track: Track
    var position: Int
    var isCurrent: Bool
    var isPlaying: Bool
    var isSelected: Bool
    var onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Tokens.Space.l) {
            Group {
                if isHovering {
                    Button(action: onToggle) {
                        CadenceIcon(isCurrent && isPlaying ? "pause.fill" : "play.fill",
                                    size: 13, boxScale: 1.25)
                            .frame(width: 28, height: 18, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .plainControl()
                    .focusable(false)
                    .accessibilityHidden(true)
                } else if isCurrent {
                    EqualizerBars(isAnimating: isPlaying)
                        .frame(width: 28, height: 18, alignment: .leading)
                } else {
                    Text(String(format: "%02d", position + 1))
                        .font(Tokens.Typography.mono(11.5))
                }
            }
            .foregroundStyle(isCurrent ? Tokens.Palette.accent : Color(hex: 0x5C5C66))
            .frame(width: 28, alignment: .leading)

            ArtworkView(artworkID: track.artworkID, cornerRadius: Tokens.Radius.thumb,
                        stripe: 4, displaySize: 40)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Tokens.Typography.trackTitle)
                    .foregroundStyle(isCurrent ? Tokens.Palette.accent : Color(hex: 0xE6E6EC))
                    .lineLimit(1)
                InlineLink(text: track.artist, font: Tokens.Typography.sans(11, .medium),
                           color: Color(hex: 0x7A7A84)) {
                    model.show(.artist(track.artist))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InlineLink(text: track.albumTitle, font: Tokens.Typography.sans(11, .medium),
                       color: Tokens.Palette.textMuted) {
                model.show(.album(track.albumKey))
            }
            .frame(width: 160, alignment: .leading)

            LikeButton(track: track, isRowHovered: isHovering)

            Text(DurationFormat.clock(track.duration))
                .font(Tokens.Typography.mono(11.5))
                .foregroundStyle(Color(hex: 0x7A7A84))
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .hoverHighlight(isActive: isCurrent || isSelected)
        .onHover { isHovering = $0 }
    }
}
