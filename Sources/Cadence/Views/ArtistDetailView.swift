import SwiftUI
import CadenceCore

/// Everything one artist has. Reaching an artist used to open whichever of
/// their albums the library happened to list first, which left the other nine
/// records unreachable from the artists screen — issue #14.
struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var artist: Artist

    /// Hover state for the header image's edit affordance. The picture is
    /// derived by default — the first album cover — and this is where the user
    /// gets to override it, so the control lives on the image itself.
    @State private var isHoveringArt = false

    private var albums: [Album] { model.albums(byArtist: artist.name) }

    /// Album order, so Play works through the discography the way the screen
    /// reads rather than in whatever order the store returned tracks.
    private var orderedTracks: [Track] {
        albums.flatMap { $0.discs.flatMap(\.tracks) }
    }

    var body: some View {
        @Bindable var model = model

        // The header rides inside the scroll view either way, so it scrolls
        // away rather than pinning a 200pt band over the records.
        switch model.artistAlbumLayout {
        case .grid:
            AlbumGrid(albums: albums, subtitle: .year,
                      scrollAnchor: $model.artistAlbumGridScrollAnchor) { header }
                .background(Tokens.Palette.surface)
        case .list:
            // Lazy so a long discography only builds the albums near the
            // viewport.
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    ForEach(albums) { album in
                        AlbumSection(album: album)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.Palette.surface)
        }
    }

    private var header: some View {
        @Bindable var model = model

        return
        HStack(alignment: .bottom, spacing: 32) {
            ArtworkView(artworkID: model.artworkID(forArtist: artist.name),
                        isCircular: true,
                        displaySize: 320)
                .frame(width: Tokens.Layout.artistHeaderArt,
                       height: Tokens.Layout.artistHeaderArt)
                .overlay { editArtOverlay }
                .shadow(color: .black.opacity(0.55), radius: 25, y: 12)
                .onHover { isHoveringArt = $0 }

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Artist", size: 10.5, color: Color(hex: 0x8D8D98))

                Text(artist.name)
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
                        guard let first = orderedTracks.first else { return }
                        playback.play(first, in: orderedTracks)
                    }
                    CapsuleButton(title: "Shuffle") {
                        playback.shuffle(orderedTracks)
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Next to the albums it rearranges, not buried in Preferences.
            layoutPicker
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
            Rectangle().fill(Color(hex: 0x1C1C21)).frame(height: 1)
        }
    }

    private var layoutPicker: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.ArtistAlbumLayout.allCases) { layout in
                let isSelected = model.artistAlbumLayout == layout
                Button { model.artistAlbumLayout = layout } label: {
                    Image(systemName: layout.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected
                                         ? Tokens.Palette.textPrimary
                                         : Tokens.Palette.textSecondary)
                        .frame(width: 34, height: 28)
                        .background {
                            RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                             style: .continuous)
                                .fill(isSelected ? Tokens.Palette.navActive : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .plainControl()
                .help(layout.help)
                .accessibilityLabel(layout.help)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.fieldBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.fieldBorder, lineWidth: 1)
        }
    }

    /// Appears over the header image on hover: a scrim behind an "Edit" pill
    /// that opens the image editor. Hidden entirely when editing isn't
    /// available (the real artwork store failed to open, or preview mode), so
    /// there is never a control that leads nowhere.
    @ViewBuilder
    private var editArtOverlay: some View {
        if model.canEditArtistImage {
            ZStack {
                Circle()
                    .fill(.black.opacity(isHoveringArt ? 0.55 : 0))
                    .allowsHitTesting(false)

                if isHoveringArt {
                    CapsuleButton(title: "Edit", systemImage: "pencil.circle.fill",
                                  accessibilityLabel: "Edit artist image") {
                        model.editingArtist = artist
                    }
                    .scaleEffect(0.82)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHoveringArt)
        }
    }

    /// `4 albums · 41 tracks · 3 hr 12 min`. The counts come from the artist
    /// row so the two screens cannot disagree about how much is here.
    private var summary: String {
        let total = orderedTracks.reduce(0) { $0 + $1.duration }
        return "\(artist.summary) · \(DurationFormat.approximate(total))"
    }
}

/// One record on the artist page: a small cover and title block, then the full
/// tracklist the album page would show. The cover is a fraction of the album
/// page's so several records fit on screen at once.
private struct AlbumSection: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var album: Album

    private var tracks: [Track] { album.discs.flatMap(\.tracks) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            AlbumTrackList(album: album)
                .padding(.horizontal, Tokens.Space.contentInset)
                .padding(.top, 18)
                .padding(.bottom, 30)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            ArtworkView(artworkID: album.artworkID,
                        cornerRadius: Tokens.Radius.card,
                        displaySize: 280)
                .frame(width: Tokens.Layout.artistAlbumArt,
                       height: Tokens.Layout.artistAlbumArt)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Button { model.show(.album(album.key)) } label: {
                    Text(album.title)
                        .font(Tokens.Typography.sans(20, .heavy))
                        .tracking(Tokens.Typography.Tracking.display)
                        .foregroundStyle(Color(hex: 0xF4F4F8))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .plainControl()
                .accessibilityHint("Opens the album page")

                Text(metadata)
                    .font(Tokens.Typography.sans(12.5, .medium))
                    .foregroundStyle(Color(hex: 0x82828D))

                if let format = album.dominantFormat {
                    HStack(spacing: Tokens.Space.s) {
                        QualityBadge(text: format.codec.name, emphasis: .accent)
                        QualityBadge(text: format.longDescription,
                                     spokenText: NowPlayingPane.spokenFormat(format))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                CapsuleButton(systemImage: "play.fill", kind: .filled,
                              accessibilityLabel: "Play \(album.title)") {
                    playback.play(album)
                }
                CapsuleButton(systemImage: "shuffle",
                              accessibilityLabel: "Shuffle \(album.title)") {
                    playback.shuffle(album)
                }
                MenuButton(systemImage: "plus",
                           accessibilityLabel: "Add album to queue or a playlist") {
                    PlaylistMenu.albumAdditions(model: model, playback: playback,
                                                tracks: tracks)
                }
            }
        }
        .padding(.horizontal, Tokens.Space.contentInset)
        .padding(.top, 26)
        .padding(.bottom, 4)
    }

    private var metadata: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append(album.trackCount == 1 ? "1 track" : "\(album.trackCount) tracks")
        if album.hasMultipleDiscs { parts.append("\(album.discCount) discs") }
        parts.append(DurationFormat.approximate(album.duration))
        return parts.joined(separator: "  ·  ")
    }
}
