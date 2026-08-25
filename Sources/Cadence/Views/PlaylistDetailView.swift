import SwiftUI
import CadenceCore

/// One playlist, open. The header is `ArtistDetailView`'s shape — a cover over
/// a name, counts and the verbs — and the body is a plain `ScrollView`, like
/// `AlbumDetailView`'s track list, reordered by dragging: a playlist is a
/// running order the user is expected to rearrange.
///
/// Not a `List`. It was one originally, driven by `onMove` — which never
/// engaged its drag in this app (#25) — and rebuilding on `.draggable`/
/// `.dropDestination` still did not fix it as long as the rows sat inside a
/// `List`. Only moving off `List` entirely, onto the same plain-stack
/// container `.draggable` already works in elsewhere (`AlbumDetailView`,
/// `LibraryView`), got a drag to actually start. See #25.
struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var playlist: Playlist

    /// The row a single click put under the cursor, as on the album screen:
    /// playback needs a second click, so something has to show what the first
    /// one did.
    @State private var selectedEntry: AppModel.PlaylistEntry.ID?
    /// The row (or the space after the last one) a drag is currently over —
    /// what draws the insertion line. `nil` when nothing is being dragged.
    @State private var dropTarget: DropTarget?

    private enum DropTarget: Hashable {
        case entry(AppModel.PlaylistEntry.EntryID)
        case end
    }

    /// Recomputed on every access — walking the playlist and its track
    /// dictionary is not free, and `dropTarget` above changes on every row
    /// boundary the cursor crosses mid-drag, re-running `body` continuously
    /// while that happens. `body` reads each of these exactly once per render
    /// and hands the result down, rather than letting `header` and
    /// `trackList` each call back into these independently.
    private var entries: [AppModel.PlaylistEntry] { model.entries(in: playlist) }
    private var tracks: [Track] { entries.map(\.track) }

    var body: some View {
        let entries = entries
        let tracks = entries.map(\.track)

        VStack(spacing: 0) {
            header(tracks: tracks)
            if entries.isEmpty {
                emptyState
            } else {
                trackList(entries: entries)
            }
        }
        .background(Tokens.Palette.surface)
    }

    // MARK: Header

    /// Fixed above the list rather than scrolling with it, unlike the album
    /// and artist screens that scroll their header away inside the same
    /// scroll view as their tracks. Here the two stay separate: `trackList`
    /// is its own `ScrollView`, sibling to this one rather than wrapping it,
    /// so nothing here competes with a drag over the tracks below.
    private func header(tracks: [Track]) -> some View {
        // A playlist has no cover of its own; the first track that has one
        // stands in, rather than the first track's — which is often the one
        // with none.
        let coverID = tracks.compactMap(\.artworkID).first

        return HStack(alignment: .bottom, spacing: 32) {
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

                    MenuButton(systemImage: "ellipsis",
                               accessibilityLabel: "More playlist actions") {
                        PlaylistMenu.actions(model: model, playback: playback,
                                             playlist: playlist)
                    }
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

    private func trackList(entries: [AppModel.PlaylistEntry]) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(entries) { entry in
                    PlaylistTrackRow(
                        entry: entry,
                        isCurrent: playback.currentTrack?.id == entry.track.id,
                        isSelected: selectedEntry == entry.id
                    )
                    .contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        if dropTarget == .entry(entry.id) { insertionLine }
                    }
                    // `.draggable` before the tap gesture, not after: it is
                    // the order `AlbumDetailView`'s track row uses, and the
                    // one place in the app that already combines a drag with
                    // both a single- and double-tap on the same view.
                    .draggable(PlaylistReorderItem(entryID: entry.id)) {
                        TrackDragPreview(systemImage: "line.3.horizontal",
                                         title: entry.track.title, detail: entry.track.artist)
                    }
                    .dropDestination(for: PlaylistReorderItem.self) { items, _ in
                        drop(items, before: entry.position)
                    } isTargeted: { targeted in
                        setTarget(.entry(entry.id), targeted: targeted)
                    }
                    .onTapGesture(count: 2) { play(entry) }
                    .onTapGesture { selectedEntry = entry.id }
                    .cadenceContextMenu(onOpen: { selectedEntry = entry.id }) {
                        PlaylistMenu.track(
                            entry.track,
                            model: model,
                            play: { play(entry) },
                            remove: ("Remove from Playlist",
                                     { remove(IndexSet([entry.position])) }))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenLabel(for: entry))
                    .accessibilityHint("Plays this track. Drag to reorder.")
                    .accessibilityAddTraits(playback.currentTrack?.id == entry.track.id
                                            || selectedEntry == entry.id
                                            ? [.isButton, .isSelected] : .isButton)
                    // VoiceOver has no double click, and no drag either: both
                    // the way in and the way out have to be reachable from
                    // the rotor.
                    .accessibilityAction(.default) { play(entry) }
                    .accessibilityAction(named: "Remove from playlist") {
                        remove(IndexSet([entry.position]))
                    }
                    // `.ignore` above also swallows the row's own artist/album
                    // links, same as it does the play button — these stand in
                    // for them on the rotor.
                    .accessibilityAction(named: "Go to artist") {
                        model.show(.artist(entry.track.artist))
                    }
                    .accessibilityAction(named: "Go to album") {
                        model.show(.album(entry.track.albumKey))
                    }
                }

                // The only way to drop after the last row: every other row
                // only accepts a drop above itself, so nothing above accepts
                // "last."
                Color.clear
                    .frame(height: 10)
                    .overlay(alignment: .top) {
                        if dropTarget == .end { insertionLine }
                    }
                    .dropDestination(for: PlaylistReorderItem.self) { items, _ in
                        drop(items, before: entries.count)
                    } isTargeted: { targeted in
                        setTarget(.end, targeted: targeted)
                    }
            }
            .padding(.horizontal, Tokens.Space.m)
            .padding(.top, Tokens.Space.m)
        }
        .scrollContentBackground(.hidden)
    }

    /// In the playlist's own order, so playing row 3 queues the rest of the
    /// playlist rather than the album that track came from.
    private func play(_ entry: AppModel.PlaylistEntry) {
        selectedEntry = entry.id
        playback.play(entry.track, in: tracks)
    }

    /// Row offsets translated to stored positions before they reach the
    /// store. The two are the same today, but a deletion aimed at the wrong
    /// row is silent and permanent, so this one does not rely on it.
    private func remove(_ offsets: IndexSet) {
        let rows = entries
        let positions = IndexSet(offsets.compactMap {
            rows.indices.contains($0) ? rows[$0].position : nil
        })
        guard !positions.isEmpty else { return }
        Task { await model.removeFromPlaylist(playlist, atOffsets: positions) }
    }

    /// A thin accent line standing in for the row that would be pushed down.
    private var insertionLine: some View {
        Rectangle().fill(Tokens.Palette.accent).frame(height: 2)
    }

    private func setTarget(_ target: DropTarget, targeted: Bool) {
        if targeted {
            dropTarget = target
        } else if dropTarget == target {
            // Only clear a target that is still this one: entering the next
            // row's drop zone fires before leaving this one's, and clearing
            // unconditionally on exit would erase the line the new row just drew.
            dropTarget = nil
        }
    }

    /// `destination` is `Ordering.move`'s convention — an index into the
    /// *current* `entries`, before the dragged row is removed — so dropping
    /// "before row 5" and "onto the space after the last row" both reduce to
    /// the same call the old `onMove` handler made.
    private func drop(_ items: [PlaylistReorderItem], before destination: Int) -> Bool {
        dropTarget = nil
        guard let dragged = items.first,
              let source = entries.firstIndex(where: { $0.id == dragged.entryID })
        else { return false }
        // Dropping a row on itself or on the gap right behind it is not a move.
        guard destination != source, destination != source + 1 else { return true }
        Task {
            await model.moveInPlaylist(playlist, fromOffsets: IndexSet([source]),
                                       toOffset: destination)
        }
        return true
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
    @Environment(AppModel.self) private var model

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
                InlineLink(text: track.artist, font: Tokens.Typography.sans(11, .medium),
                           color: Color(hex: 0x6A6A74)) {
                    model.show(.artist(track.artist))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InlineLink(text: track.albumTitle, font: Tokens.Typography.sans(11, .medium),
                       color: Tokens.Palette.textMuted) {
                model.show(.album(track.albumKey))
            }
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
