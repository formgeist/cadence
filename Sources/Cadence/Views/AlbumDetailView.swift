import SwiftUI
import CadenceCore

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var album: Album

    /// The row a single click put under the cursor, and the row an arrow key
    /// last moved to — the same state serves both, so a keyboard user picks up
    /// exactly where a mouse user would have left off. Playback needs a
    /// second click or a `Return`, so something has to show what either one
    /// did.
    @State private var selectedTrackID: Track.ID?
    @FocusState private var isTrackListFocused: Bool
    @State private var typeAhead = TypeAheadBuffer()

    private var orderedTracks: [Track] { album.discs.flatMap(\.tracks) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    header
                    trackList
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.Palette.surface)
            .onChange(of: selectedTrackID) { _, new in
                guard let new else { return }
                proxy.scrollTo(new, anchor: .center)
            }
        }
        // A different album, reached without this view ever leaving the
        // screen — `RootView` keeps the same `.album` case on the switch when
        // you jump from one record to another — so a stale id here would
        // otherwise point at a track that isn't on screen at all.
        .onChange(of: album.key) { _, _ in selectedTrackID = nil }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 48) {
            ArtworkView(
                artworkID: album.artworkID,
                cornerRadius: Tokens.Radius.card,
                caption: album.artworkID == nil ? "NO ARTWORK" : "ALBUM ARTWORK\n1400 × 1400",
                captionSize: 10,
                stripe: 7,
                displaySize: 320
            )
            .frame(width: Tokens.Layout.albumHeaderArt, height: Tokens.Layout.albumHeaderArt)
            .shadow(color: .black.opacity(0.55), radius: 25, y: 12)

            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(album.isCompilation ? "Compilation" : "Album",
                             size: 10.5, color: Color(hex: 0x8D8D98))

                Text(album.title)
                    .font(Tokens.Typography.display)
                    .tracking(Tokens.Typography.Tracking.display)
                    .foregroundStyle(Color(hex: 0xF4F4F8))
                    .lineSpacing(-4)
                    // The design's title is one line. Real ones are not; three
                    // lines is where a 46pt face stops being a headline.
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                metadataLine
                badges

                HStack(spacing: 10) {
                    CapsuleButton(title: "Play", systemImage: "play.fill", kind: .filled) {
                        playback.play(album)
                    }
                    CapsuleButton(title: "Shuffle") { playback.shuffle(album) }
                    // A menu, not a button: the queue was the only thing an
                    // album could be added to, and a playlist is the other
                    // obvious answer to the same plus.
                    MenuButton(systemImage: "plus",
                               accessibilityLabel: "Add album to queue or a playlist") {
                        PlaylistMenu.albumAdditions(model: model, playback: playback,
                                                    tracks: orderedTracks)
                    }
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Tokens.Space.albumInset)
        .padding(.top, 38)
        .padding(.bottom, 30)
        .background {
            LinearGradient(
                colors: [Tokens.Palette.immersiveTop, Tokens.Palette.surface],
                startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0x1C1C21)).frame(height: 1)
        }
    }

    /// The artist needs its own tap target, so it can no longer join the rest
    /// in one concatenated `Text` — a `Text` built from `+` has no room for a
    /// `Button` in the middle. `.layoutPriority(1)` takes over the job that
    /// concatenation used to do for free: without it, an HStack takes the
    /// shrinkage out of the first child, so a box set with an extra "3 discs"
    /// part would truncate the album artist — the one thing on the line you
    /// cannot lose — while empty space sat to its right.
    private var metadataLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            InlineLink(text: album.albumArtist, font: Tokens.Typography.sans(13.5, .semibold),
                       color: Color(hex: 0xB4B4BD)) {
                model.show(.artist(album.albumArtist))
            }
            .layoutPriority(1)

            metadataSuffix
        }
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "  ·  2020  ·  12 tracks  ·  35 min" — everything on `metadataLine`
    /// after the artist link, still one concatenated `Text` so the separators
    /// keep their own dim color without becoming views of their own.
    private var metadataSuffix: some View {
        var line = Text("")
        for part in metadataParts {
            line = line
                + Text("  ·  ").foregroundColor(Color(hex: 0x45454E))
                + Text(part)
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundColor(Color(hex: 0x82828D))
        }
        return line
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append(album.trackCount == 1 ? "1 track" : "\(album.trackCount) tracks")
        // A box set says so here rather than making you count disc headers.
        if album.hasMultipleDiscs { parts.append("\(album.discCount) discs") }
        parts.append(DurationFormat.approximate(album.duration))
        return parts
    }

    private var badges: some View {
        HStack(spacing: Tokens.Space.s) {
            if let format = album.dominantFormat {
                QualityBadge(text: format.codec.name, emphasis: .accent)
                QualityBadge(text: format.longDescription,
                             spokenText: NowPlayingPane.spokenFormat(format))
            }
        }
        .padding(.top, 2)
    }

    // MARK: Tracks

    private var trackList: some View {
        // Lazy so a box set or a 200-track classical box doesn't instantiate
        // every row on open — only what the shared `ScrollView` can show. The
        // header scrolls away with the list, so this is the inner list only;
        // `PlaylistDetailView` does the same for its rows. See #87.
        LazyVStack(spacing: 0) {
            columnHeader
            ForEach(album.discs) { disc in
                if let number = disc.number {
                    HStack(spacing: 14) {
                        SectionLabel("Disc \(number)", size: 10,
                                     color: Tokens.Palette.textMuted)
                        Rectangle().fill(Tokens.Palette.separator).frame(height: 1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, Tokens.Space.xl)
                    .padding(.bottom, Tokens.Space.s)
                }
                ForEach(disc.tracks) { track in
                    TrackRow(
                        track: track,
                        isCurrent: playback.currentTrack?.id == track.id,
                        isSelected: selectedTrackID == track.id,
                        showsArtist: album.showsTrackArtists,
                        onSelect: { selectedTrackID = track.id },
                        onPlay: {
                            selectedTrackID = track.id
                            playback.play(track, in: orderedTracks)
                        }
                    )
                    .id(track.id)
                    .simultaneousGesture(TapGesture().onEnded { isTrackListFocused = true })
                    .cadenceContextMenu(onOpen: { selectedTrackID = track.id }) {
                        PlaylistMenu.track(
                            track,
                            model: model,
                            play: {
                                selectedTrackID = track.id
                                playback.play(track, in: orderedTracks)
                            },
                            addToQueue: { playback.appendToQueue([track]) })
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isTrackListFocused)
        .onKeyPress { handleTrackListKeyPress($0) }
        // Arrow keys, not `.onKeyPress`: `ScrollView` implements the same
        // `moveUp:`/`moveDown:` responder actions for its own line-scrolling
        // and wins them before a nested `.onKeyPress` ever sees the event.
        // `.onMoveCommand` hooks those same selectors, so this handler is the
        // one that answers instead of the scroll view swallowing them.
        .onMoveCommand { direction in
            guard let direction = GridNavigation.Direction(direction),
                  direction == .up || direction == .down else { return }
            let current = orderedTracks.firstIndex { $0.id == selectedTrackID }
            if let index = GridNavigation.move(from: current, by: direction,
                                               count: orderedTracks.count, columns: 1) {
                selectedTrackID = orderedTracks[index].id
            }
        }
        .onChange(of: isTrackListFocused) { _, focused in
            if focused, selectedTrackID == nil { selectedTrackID = orderedTracks.first?.id }
        }
        .padding(.horizontal, Tokens.Space.albumInset)
        .padding(.top, 22)
        .padding(.bottom, 44)
    }

    private func handleTrackListKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        if press.key == .return {
            if let selectedTrackID,
               let track = orderedTracks.first(where: { $0.id == selectedTrackID }) {
                playback.play(track, in: orderedTracks)
            }
            return .handled
        }
        if let character = press.characters.first, character.isLetter || character.isNumber {
            let current = orderedTracks.firstIndex { $0.id == selectedTrackID }
            if let index = typeAhead.index(for: character, current: current,
                                           keys: orderedTracks.map(\.title)) {
                selectedTrackID = orderedTracks[index].id
            }
            return .handled
        }
        return .ignored
    }

    private var columnHeader: some View {
        HStack(spacing: Tokens.Space.l) {
            Text("#").frame(width: 28, alignment: .leading)
            Text("TITLE").frame(maxWidth: .infinity, alignment: .leading)
            Text("QUALITY").frame(width: 90, alignment: .leading)
            Text("TIME").frame(width: 56, alignment: .trailing)
        }
        // Column headings are a visual aid; each row states its own values.
        .accessibilityHidden(true)
        .font(Tokens.Typography.mono(10, .medium))
        .tracking(1.2)
        .foregroundStyle(Tokens.Palette.textMuted)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.Palette.separator).frame(height: 1)
        }
    }
}

/// A track row plays on double click, not on the first one: single-clicking a
/// list to move around it should not restart the music — issue #16. The play
/// glyph that replaces the track number on hover is a real button, so one
/// deliberate click still works.
private struct TrackRow: View {
    @Environment(AppModel.self) private var model

    var track: Track
    var isCurrent: Bool
    var isSelected: Bool
    /// On a single-artist album, repeating the album artist under every title
    /// is noise. On a compilation it is the most useful column on the screen.
    var showsArtist: Bool
    var onSelect: () -> Void
    var onPlay: () -> Void

    @State private var isHovering = false
    /// Where the pointer last was inside this row, in the row's own
    /// coordinates. Read at drag start to decide where the chip appears; the
    /// pointer is by definition over the row when the drag begins.
    @State private var pointer: CGPoint = .zero
    @State private var rowSize: CGSize = .zero

    var body: some View {
        row
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .hoverHighlight(isActive: isCurrent || isSelected)
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
            // The whole row drags, not just the title.
            .draggable(TrackSelection([track.id])) {
                TrackDragPreview.track(track).anchored(in: rowSize, at: pointer)
            }
            .onTapGesture(count: 2, perform: onPlay)
            .onTapGesture(perform: onSelect)
            .onHover { isHovering = $0 }
            .pointingHandCursor()
            // One stop per track, reading as a sentence, instead of four stops
            // reading "01", a title, "16/44.1", "4:12".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
            .accessibilityAddTraits(isCurrent || isSelected
                                    ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Plays this track")
            // VoiceOver has no double click. Activating the row plays it,
            // which is what the hint promises.
            .accessibilityAction(.default, onPlay)
            // `.ignore` above also swallows the artist link in `row` when it's
            // showing — offered only when that link is actually on screen.
            .accessibilityAction(named: "Go to artist", isAvailable: artistLinkTarget != nil) {
                if let artistLinkTarget { model.show(.artist(artistLinkTarget)) }
            }
    }

    /// The artist name shown as a link under the title, matching `row`'s own
    /// composer-vs-artist choice — nil when the row shows a composer instead,
    /// or shows no subtitle at all.
    private var artistLinkTarget: String? {
        guard track.composer == nil || track.composer!.isEmpty else { return nil }
        return track.rowSubtitle(showingArtist: showsArtist) != nil ? track.artist : nil
    }

    private var row: some View {
        HStack(spacing: Tokens.Space.l) {
            Group {
                if isHovering {
                    // A deliberate single click still plays, so the double
                    // click is the safeguard and not the only way in.
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                            .frame(width: 28, height: 18, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .plainControl()
                    .focusable(false)
                    // The row already says all of this, and says it better.
                    .accessibilityHidden(true)
                } else {
                    Text(track.trackNumber.map { String(format: "%02d", $0) } ?? "–")
                        .font(Tokens.Typography.mono(11.5))
                }
            }
            .foregroundStyle(isCurrent ? Tokens.Palette.accent : Color(hex: 0x5C5C66))
            .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Tokens.Typography.trackTitle)
                    .foregroundStyle(isCurrent
                                     ? Tokens.Palette.accent : Color(hex: 0xE6E6EC))
                    .lineLimit(1)
                // The composer isn't a page this app has, so only the artist
                // half of `rowSubtitle` becomes a link.
                if let artistLinkTarget {
                    InlineLink(text: artistLinkTarget, font: Tokens.Typography.sans(11, .medium),
                               color: Color(hex: 0x6A6A74)) {
                        model.show(.artist(artistLinkTarget))
                    }
                } else if let subtitle = track.rowSubtitle(showingArtist: showsArtist) {
                    Text(subtitle)
                        .font(Tokens.Typography.sans(11, .medium))
                        .foregroundStyle(Color(hex: 0x6A6A74))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.format.shortDescription)
                .font(Tokens.Typography.mono(10.5))
                .foregroundStyle(Tokens.Palette.textMuted)
                .frame(width: 90, alignment: .leading)

            Text(DurationFormat.clock(track.duration))
                .font(Tokens.Typography.mono(11.5))
                .foregroundStyle(Color(hex: 0x7A7A84))
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var spokenLabel: String {
        var parts: [String] = []
        if let number = track.trackNumber { parts.append("Track \(number)") }
        parts.append(track.title)
        if let subtitle = track.rowSubtitle(showingArtist: showsArtist) {
            parts.append(subtitle)
        }
        parts.append(NowPlayingPane.spokenDuration(track.duration))
        parts.append(NowPlayingPane.spokenFormat(track.format))
        if isCurrent { parts.append("Now playing") }
        return parts.joined(separator: ", ")
    }
}
