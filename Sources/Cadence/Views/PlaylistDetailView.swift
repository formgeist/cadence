import SwiftUI
import CadenceCore

/// One playlist, open. The header is `ArtistDetailView`'s shape — a cover over
/// a name, counts and the verbs — and the body is `QueueList`'s: a `List` with
/// `onMove` and `onDelete`, because a playlist is a running order the user is
/// expected to rearrange.
struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var playlist: Playlist

    /// The row a single click put under the cursor, as on the album screen:
    /// playback needs a second click, so something has to show what the first
    /// one did.
    @State private var selectedEntry: AppModel.PlaylistEntry.ID?

    private var entries: [AppModel.PlaylistEntry] { model.entries(in: playlist) }
    private var tracks: [Track] { entries.map(\.track) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if entries.isEmpty {
                emptyState
            } else {
                trackList
            }
        }
        .background(Tokens.Palette.surface)
    }

    // MARK: Header

    /// Fixed above the list rather than scrolling with it, unlike the album and
    /// artist screens. Those scroll their header away inside one scroll view;
    /// a `List` brings its own, and nesting the two is what turns a drag near
    /// the top edge into a fight between them.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 32) {
            ArtworkView(
                artworkID: coverID,
                cornerRadius: Tokens.Radius.card,
                caption: coverID == nil ? "EMPTY PLAYLIST" : nil,
                captionSize: 10,
                stripe: 7,
                displaySize: 320
            )
            .frame(width: Tokens.Layout.artistHeaderArt, height: Tokens.Layout.artistHeaderArt)
            .shadow(color: .black.opacity(0.55), radius: 25, y: 12)

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Playlist", size: 10.5, color: Color(hex: 0x8D8D98))

                Text(playlist.name)
                    .font(Tokens.Typography.sans(38, .heavy))
                    .tracking(Tokens.Typography.Tracking.display)
                    .foregroundStyle(Color(hex: 0xF4F4F8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(summary)
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundStyle(Color(hex: 0x82828D))

                HStack(spacing: 10) {
                    CapsuleButton(title: "Play", systemImage: "play.fill", kind: .filled) {
                        guard let first = tracks.first else { return }
                        playback.play(first, in: tracks)
                    }
                    .disabled(tracks.isEmpty)

                    CapsuleButton(title: "Shuffle") { playback.shuffle(tracks) }
                        .disabled(tracks.isEmpty)

                    CapsuleButton(systemImage: "plus",
                                  accessibilityLabel: "Add playlist to queue") {
                        playback.appendToQueue(tracks)
                    }
                    .disabled(tracks.isEmpty)

                    Menu {
                        PlaylistActionButtons(model: model, playback: playback,
                                              playlist: playlist)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More playlist actions")
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

    /// A playlist has no cover of its own; the first track that has one stands
    /// in, rather than the first track's — which is often the one with none.
    private var coverID: Artwork.ID? {
        tracks.compactMap(\.artworkID).first
    }

    /// `12 tracks · 47 min`. The duration comes off the playlist rather than
    /// being summed here, so it matches the figure the sidebar quotes even
    /// when a track has left the library since.
    private var summary: String {
        "\(playlist.summary) · \(DurationFormat.approximate(playlist.duration))"
    }

    // MARK: Tracks

    private var emptyState: some View {
        EmptyState(
            systemImage: "music.note.list",
            title: "Nothing in here yet",
            message: "Drag tracks onto this playlist in the sidebar,\nor use Add to Playlist from any album."
        ) {
            EmptyView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackList: some View {
        // A `List`, for the same reason `QueueList` is one: `onMove` is the
        // only reordering that behaves the way macOS users expect — grab
        // anywhere, autoscroll at the edges, drop where the line shows.
        // Selection is the List's own rather than a tap gesture, for the same
        // reason the double click below is declared simultaneous: an exclusive
        // gesture on a row swallows the press `onMove` needs.
        List(selection: $selectedEntry) {
            ForEach(entries) { entry in
                PlaylistTrackRow(
                    entry: entry,
                    isCurrent: playback.currentTrack?.id == entry.track.id,
                    isSelected: selectedEntry == entry.id
                )
                .tag(entry.id)
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .contentShape(Rectangle())
                // `.simultaneousGesture`, not `.onTapGesture`. A tap gesture is
                // exclusive: it claims the press for itself and only gives it
                // up once it has failed, and `onMove` needs that press to start
                // its drag. Removing the single-click tap in #24 was not enough
                // because this one was still here, so the row still highlighted
                // and never lifted. Declared simultaneous, the double click
                // still plays and the press also reaches the reorder.
                .simultaneousGesture(TapGesture(count: 2).onEnded { play(entry) })
                // Deliberately not `.draggable`. `onMove` brings its own drag,
                // and a row carrying both hands the reorder gesture to the
                // wrong one — you go to move a track up two places and instead
                // start dragging it at the sidebar. Sending a track to another
                // playlist from here is the context menu's job.
                .contextMenu {
                    Button("Play") { play(entry) }
                    AddToPlaylistMenu(model: model, tracks: [entry.track])
                    Divider()
                    Button("Remove from Playlist", role: .destructive) {
                        remove(IndexSet([entry.position]))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenLabel(for: entry))
                .accessibilityHint("Plays this track. Drag to reorder.")
                .accessibilityAddTraits(playback.currentTrack?.id == entry.track.id
                                        || selectedEntry == entry.id
                                        ? [.isButton, .isSelected] : .isButton)
                // VoiceOver has no double click, and no drag either: both the
                // way in and the way out have to be reachable from the rotor.
                .accessibilityAction(.default) { play(entry) }
                .accessibilityAction(named: "Remove from playlist") {
                    remove(IndexSet([entry.position]))
                }
            }
            // Offsets pass straight through: `entries` is one row per stored
            // item, in stored order. It stays that way because
            // `playlistItem.trackID` cascades — an item cannot outlive the
            // track it points at — so there is never an unresolvable id to
            // drop and shift everything below it by one.
            .onMove { source, destination in
                Task {
                    await model.moveInPlaylist(playlist, fromOffsets: source,
                                               toOffset: destination)
                }
            }
            .onDelete(perform: remove)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 44)
        .padding(.horizontal, Tokens.Space.m)
        .padding(.top, Tokens.Space.m)
    }

    /// In the playlist's own order, so playing row 3 queues the rest of the
    /// playlist rather than the album that track came from.
    private func play(_ entry: AppModel.PlaylistEntry) {
        selectedEntry = entry.id
        playback.play(entry.track, in: tracks)
    }

    /// Row offsets translated to stored positions before they reach the store.
    /// The two are the same today — see `onMove` — but a deletion aimed at the
    /// wrong row is silent and permanent, so this one does not rely on it.
    private func remove(_ offsets: IndexSet) {
        let rows = entries
        let positions = IndexSet(offsets.compactMap {
            rows.indices.contains($0) ? rows[$0].position : nil
        })
        guard !positions.isEmpty else { return }
        Task { await model.removeFromPlaylist(playlist, atOffsets: positions) }
    }

    private func spokenLabel(for entry: AppModel.PlaylistEntry) -> String {
        var parts = ["\(entry.position + 1)", entry.track.title, entry.track.artist]
        parts.append(NowPlayingPane.spokenDuration(entry.track.duration))
        if playback.currentTrack?.id == entry.track.id { parts.append("Now playing") }
        return parts.joined(separator: ", ")
    }
}

/// The playlist's own row. Numbered by position rather than by tag: a playlist
/// is a running order, and the track's own "07" would say nothing about where
/// it sits in this one.
private struct PlaylistTrackRow: View {
    var entry: AppModel.PlaylistEntry
    var isCurrent: Bool
    var isSelected: Bool

    private var track: Track { entry.track }

    var body: some View {
        HStack(spacing: Tokens.Space.l) {
            Text(String(format: "%02d", entry.position + 1))
                .font(Tokens.Typography.mono(11.5))
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
                // Always the artist here, never nil as on an album screen: a
                // playlist has no single artist to make repeating one noise.
                Text(track.artist)
                    .font(Tokens.Typography.sans(11, .medium))
                    .foregroundStyle(Color(hex: 0x6A6A74))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.albumTitle)
                .font(Tokens.Typography.sans(11, .medium))
                .foregroundStyle(Tokens.Palette.textMuted)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            Text(DurationFormat.clock(track.duration))
                .font(Tokens.Typography.mono(11.5))
                .foregroundStyle(Color(hex: 0x7A7A84))
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .hoverHighlight(isActive: isCurrent || isSelected)
    }
}
