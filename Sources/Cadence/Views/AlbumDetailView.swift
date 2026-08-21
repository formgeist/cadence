import SwiftUI
import CadenceCore

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var album: Album

    /// The row a single click put under the cursor. Playback needs a second
    /// click, so something has to show what the first one did.
    @State private var selectedTrackID: Track.ID?

    private var orderedTracks: [Track] { album.discs.flatMap(\.tracks) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                trackList
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.Palette.surface)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 48) {
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
                    Menu {
                        Button("Add to Queue") { playback.appendToQueue(orderedTracks) }
                        Divider()
                        AddToPlaylistMenu(model: model, tracks: orderedTracks)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 38, height: 38)
                            .overlay { Capsule().strokeBorder(Color(hex: 0x32323B),
                                                              lineWidth: 1) }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(Color(hex: 0xCACAD3))
                    .accessibilityLabel("Add album to queue or a playlist")
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

    /// One concatenated `Text` rather than an HStack of them. In a stack,
    /// SwiftUI takes the shrinkage out of the first child, so a box set with
    /// an extra "3 discs" part truncated the album artist — the one thing on
    /// the line you cannot lose — while empty space sat to its right.
    private var metadataLine: some View {
        var line = Text(album.albumArtist)
            .font(Tokens.Typography.sans(13.5, .semibold))
            .foregroundColor(Color(hex: 0xB4B4BD))

        for part in metadataParts {
            line = line
                + Text("  ·  ").foregroundColor(Color(hex: 0x45454E))
                + Text(part)
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundColor(Color(hex: 0x82828D))
        }

        return line
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
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
        VStack(spacing: 0) {
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
                    .contextMenu {
                        Button("Play") {
                            selectedTrackID = track.id
                            playback.play(track, in: orderedTracks)
                        }
                        Button("Add to Queue") { playback.appendToQueue([track]) }
                        Divider()
                        AddToPlaylistMenu(model: model, tracks: [track])
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Space.albumInset)
        .padding(.top, 22)
        .padding(.bottom, 44)
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
                if let subtitle = track.rowSubtitle(showingArtist: showsArtist) {
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
