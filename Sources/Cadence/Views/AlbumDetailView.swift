import SwiftUI
import CadenceCore

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var album: Album

    private var orderedTracks: [Track] { album.discs.flatMap(\.tracks) }

    /// The loaded track belongs to this album — Play resumes it, not restarts.
    private var isAlbumLoaded: Bool {
        guard let id = playback.currentTrack?.id else { return false }
        return orderedTracks.contains { $0.id == id }
    }

    private var isAlbumPlaying: Bool { isAlbumLoaded && playback.isPlaying }

    /// The artist's other records, so a neighbouring album is one click from
    /// the bottom of this one.
    private var otherAlbums: [Album] {
        model.albums(byArtist: album.albumArtist).filter { $0.key != album.key }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                AlbumTrackList(album: album)
                    .padding(.horizontal, Tokens.Space.albumInset)
                    .padding(.top, 22)
                    .padding(.bottom, otherAlbums.isEmpty ? 44 : 36)
                MoreFromArtist(artist: album.albumArtist, albums: otherAlbums)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.Palette.surface)
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
                    PlayPauseButton(isPlaying: isAlbumPlaying, subject: album.title) {
                        // Mid-album, the button drives the transport; it only
                        // starts the record over when something else is loaded.
                        if isAlbumLoaded { playback.togglePlayPause() } else { playback.play(album) }
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
}

/// One album's column header and rows, with the selection, keyboard and
/// credits behaviour that goes with them. Shared by the album page and the
/// artist page, which stacks one of these per record.
struct AlbumTrackList: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var album: Album

    /// The row a single click put under the cursor, and the row an arrow key
    /// last moved to — the same state serves both, so a keyboard user picks up
    /// exactly where a mouse user would have left off. Playback needs a
    /// second click or a `Return`, so something has to show what either one
    /// did.
    @State private var selectedTrackID: Track.ID?
    /// Set alongside `selectedTrackID` only when the keyboard moved the
    /// selection — arrow keys, type-ahead, first focus — so the list scrolls
    /// to follow it. A click or ⌘-click sets `selectedTrackID` directly and
    /// leaves this alone: that row is already on screen, and centering it
    /// anyway reads as the list jumping under the pointer.
    @State private var keyboardScrollTarget: Track.ID?
    /// Focus lives on the rows, not on the list as a whole. Focusing a view
    /// scrolls it into sight, and a `focusable()` list taller than the window
    /// scrolled to its own top on every click — the page jumping up whenever
    /// you had scrolled down and picked a track. A row is on screen already
    /// when it takes focus, so there is nothing to scroll.
    @FocusState private var focusedTrackID: Track.ID?
    @State private var typeAhead = TypeAheadBuffer()
    @State private var isShowingCredits = false

    private var orderedTracks: [Track] { album.discs.flatMap(\.tracks) }

    var body: some View {
        // The reader sits inside the caller's `ScrollView`, so its proxy
        // scrolls that one — the album page and the artist page both host
        // this list in their own.
        ScrollViewReader { proxy in
            list
                .onChange(of: keyboardScrollTarget) { _, new in
                    guard let new else { return }
                    proxy.scrollTo(new, anchor: .center)
                    // After the scroll, so the row exists to take focus.
                    DispatchQueue.main.async { focusedTrackID = new }
                }
        }
        // A different album, reached without this view ever leaving the
        // screen — `RootView` keeps the same `.album` case on the switch when
        // you jump from one record to another — so a stale id here would
        // otherwise point at a track that isn't on screen at all.
        .onChange(of: album.key) { _, _ in
            selectedTrackID = nil
            keyboardScrollTarget = nil
            focusedTrackID = nil
        }
        .sheet(isPresented: $isShowingCredits) {
            AlbumCreditsSheet(album: album)
        }
    }

    private var list: some View {
        // Lazy so a box set or a 200-track classical box doesn't instantiate
        // every row on open — only what the shared `ScrollView` can show. The
        // header scrolls away with the list, so this is the inner list only;
        // `PlaylistDetailView` does the same for its rows. See #87.
        // Asked once here, not per row: every row's menu offers the same sheet.
        let hasCredits = album.tracks.contains { !$0.allCredits.isEmpty }
        return LazyVStack(spacing: 0) {
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
                        isPlaying: playback.isPlaying,
                        isSelected: selectedTrackID == track.id,
                        showsArtist: album.showsTrackArtists,
                        onSelect: { selectedTrackID = track.id },
                        onToggle: {
                            selectedTrackID = track.id
                            if playback.currentTrack?.id == track.id {
                                playback.togglePlayPause()
                            } else {
                                playback.play(track, in: orderedTracks)
                            }
                        },
                        onPlay: {
                            selectedTrackID = track.id
                            playback.play(track, in: orderedTracks)
                        }
                    )
                    .id(track.id)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focusedTrackID, equals: track.id)
                    .simultaneousGesture(TapGesture().onEnded { focusedTrackID = track.id })
                    .onKeyPress { handleTrackListKeyPress($0) }
                    // Arrow keys, not `.onKeyPress`: `ScrollView` implements the same
                    // `moveUp:`/`moveDown:` responder actions for its own line-scrolling
                    // and wins them before a nested `.onKeyPress` ever sees the event.
                    // `.onMoveCommand` hooks those same selectors, so this handler is the
                    // one that answers instead of the scroll view swallowing them.
                    .onMoveCommand { handleMove($0) }
                    .cadenceContextMenu(onOpen: { selectedTrackID = track.id }) {
                        PlaylistMenu.track(
                            track,
                            model: model,
                            play: {
                                selectedTrackID = track.id
                                playback.play(track, in: orderedTracks)
                            },
                            addToQueue: { playback.appendToQueue([track]) },
                            // Only offered when the tags name someone: an
                            // empty sheet is a menu item that lied.
                            showCredits: hasCredits ? { isShowingCredits = true } : nil)
                    }
                }
            }
        }
        // Tabbing into the list lands on a row; selection follows focus.
        .onChange(of: focusedTrackID) { _, id in
            if let id { selectedTrackID = id }
        }
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        guard let direction = GridNavigation.Direction(direction),
              direction == .up || direction == .down else { return }
        let current = orderedTracks.firstIndex { $0.id == selectedTrackID }
        if let index = GridNavigation.move(from: current, by: direction,
                                           count: orderedTracks.count, columns: 1) {
            selectedTrackID = orderedTracks[index].id
            keyboardScrollTarget = orderedTracks[index].id
        }
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
                keyboardScrollTarget = orderedTracks[index].id
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
    /// Whether audio is running, so the current row can show pause and a
    /// moving equalizer rather than a static mark.
    var isPlaying: Bool
    var isSelected: Bool
    /// On a single-artist album, repeating the album artist under every title
    /// is noise. On a compilation it is the most useful column on the screen.
    var showsArtist: Bool
    var onSelect: () -> Void
    /// The hover glyph: pause or resume on the current row, play elsewhere.
    var onToggle: () -> Void
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

    /// The artist name shown as a link under the title — nil when the row
    /// shows no subtitle at all.
    private var artistLinkTarget: String? {
        track.rowSubtitle(showingArtist: showsArtist) != nil ? track.artist : nil
    }

    private var row: some View {
        HStack(spacing: Tokens.Space.l) {
            Group {
                if isHovering {
                    // A deliberate single click still plays, so the double
                    // click is the safeguard and not the only way in.
                    Button(action: onToggle) {
                        Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 18, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .plainControl()
                    .focusable(false)
                    // The row already says all of this, and says it better.
                    .accessibilityHidden(true)
                } else if isCurrent {
                    // A shape, not just a color, marks the playing track —
                    // color alone is invisible to colorblind users and under
                    // Differentiate Without Color.
                    EqualizerBars(isAnimating: isPlaying)
                        .frame(width: 28, height: 18, alignment: .leading)
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
                if let artistLinkTarget {
                    InlineLink(text: artistLinkTarget, font: Tokens.Typography.sans(11, .medium),
                               color: Color(hex: 0x7A7A84)) {
                        model.show(.artist(artistLinkTarget))
                    }
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

/// Three bars bouncing out of phase — the "this one is playing" mark. Holds
/// still at a low height when paused, and under Reduce Motion.
struct EqualizerBars: View {
    var isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 14
    private static let phases: [Double] = [0, 1.7, 3.4]
    private static let speeds: [Double] = [5.2, 6.8, 4.4]

    var body: some View {
        let moving = isAnimating && !reduceMotion
        TimelineView(.animation(paused: !moving)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let level = moving
                        ? 0.25 + 0.75 * (0.5 + 0.5 * sin(t * Self.speeds[i] + Self.phases[i]))
                        : 0.4
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: 3, height: Self.height * level)
                }
            }
            .frame(height: Self.height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// "More from <artist>" under the tracklist. A plain grid, not `AlbumGrid`:
/// that one owns a `ScrollView`, and this sits inside the album page's.
private struct MoreFromArtist: View {
    @Environment(AppModel.self) private var model

    var artist: String
    var albums: [Album]

    /// Past this many the section stops being a shortcut and starts being the
    /// artist page again, so the rest sit behind a link to it.
    static let limit = 5

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                HStack(spacing: 14) {
                    SectionLabel("More from \(artist)", size: 10,
                                 color: Tokens.Palette.textMuted)
                    Rectangle().fill(Tokens.Palette.separator).frame(height: 1)
                }
                // Adaptive is fine at this size; it is only the full library
                // grid where it stops being lazy. See `AlbumGrid`.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: model.albumColumnWidth),
                                       spacing: Tokens.Space.xl, alignment: .top)],
                    alignment: .leading,
                    spacing: Tokens.Space.xxl
                ) {
                    ForEach(Array(albums.prefix(Self.limit).enumerated()), id: \.element.id) { index, album in
                        AlbumCard(album: album, subtitle: .year, index: index)
                            .equatable()
                    }
                }
                if albums.count > Self.limit {
                    CapsuleButton(title: "View all", systemImage: "arrow.right",
                                  accessibilityLabel: "View all albums by \(artist)") {
                        model.show(.artist(artist))
                    }
                }
            }
            .padding(.horizontal, Tokens.Space.albumInset)
            .padding(.bottom, 44)
        }
    }
}
