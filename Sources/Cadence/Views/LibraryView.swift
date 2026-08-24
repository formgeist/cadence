import SwiftUI
import CadenceCore

/// Artists, Albums and Playlists behind a shared header. The design's header is
/// sticky with a blur; here it is simply fixed above the scroll view, which
/// looks the same and avoids pinning a blurred layer over a fast list.
struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            switch model.tab {
            case .albums:
                // Brings its own scroll view: the column count depends on the
                // width, which needs a GeometryReader outside the scrolling.
                AlbumGrid(albums: model.albums)
            case .artists:
                ArtistGrid()
            case .playlists:
                if model.playlists.isEmpty {
                    PlaylistsEmptyState()
                } else {
                    ScrollView { PlaylistList() }
                        .scrollContentBackground(.hidden)
                }
            }
        }
        .background(Tokens.Palette.surface)
    }

    private var header: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                Text(model.tab.rawValue)
                    .font(Tokens.Typography.screenTitle)
                    .tracking(Tokens.Typography.Tracking.screenTitle)
                    .foregroundStyle(Tokens.Palette.textPrimary)

                Spacer()

                HStack(spacing: Tokens.Space.l) {
                    if model.tab == .albums {
                        GridZoomControl(zoom: $model.gridZoom)
                    }
                    Text(model.screenCount)
                        .font(Tokens.Typography.mono(11))
                        .foregroundStyle(Color(hex: 0x63636D))
                }
                .padding(.bottom, 6)
            }
            .padding(.bottom, 18)

            HStack(spacing: Tokens.Space.xxl) {
                ForEach(AppModel.Tab.allCases) { tab in
                    TabButton(tab: tab, isSelected: model.tab == tab) {
                        model.tab = tab
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Space.contentInset)
        .padding(.top, Tokens.Space.xxl)
        .background(Tokens.Palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0x1C1C21)).frame(height: 1)
        }
    }
}

private struct TabButton: View {
    var tab: AppModel.Tab
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tab.rawValue)
                .font(Tokens.Typography.sans(13, .bold))
                .foregroundStyle(isSelected ? Tokens.Palette.textPrimary : Color(hex: 0x6D6D77))
                .padding(.bottom, Tokens.Space.m)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? Tokens.Palette.accent : .clear)
                        .frame(height: 2)
                }
        }
        .plainControl()
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The design's two squares and a track. Clicking the squares steps the zoom;
/// the bar is draggable.
private struct GridZoomControl: View {
    @Binding var zoom: Double

    var body: some View {
        HStack(spacing: 9) {
            Button { zoom = max(0, zoom - 0.25) } label: {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color(hex: 0x6A6A74), lineWidth: 1.2)
                    .frame(width: 9, height: 9)
            }
            .plainControl()
            .accessibilityLabel("Smaller album covers")

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: 0x26262D))
                    Capsule().fill(Tokens.Palette.accent).frame(width: zoom * width)
                    Circle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .offset(x: zoom * width - 4.5)
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { zoom = min(max(0, $0.location.x / width), 1) }
                )
            }
            .frame(width: 96, height: 14)
            .accessibilityRepresentation {
                Slider(value: $zoom, in: 0...1, step: 0.1)
                    .accessibilityLabel("Album cover size")
                    .accessibilityValue("\(Int((zoom * 100).rounded())) percent")
            }

            Button { zoom = min(1, zoom + 0.25) } label: {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(hex: 0x6A6A74), lineWidth: 1.2)
                    .frame(width: 14, height: 14)
            }
            .plainControl()
            .accessibilityLabel("Larger album covers")
        }
    }
}

// MARK: - Artists

/// A grid, not a list. The format column the list carried is gone with it:
/// every file in the library is lossless, so "FLAC" on every row was a column
/// that never varied — see issue #17.
private struct ArtistGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Fixed columns for the same reason `AlbumGrid` uses them: adaptive
        // ones lay out every item before drawing any.
        GeometryReader { geometry in
            let available = geometry.size.width - Tokens.Space.contentInset * 2
            let columns = GridMetrics.columnCount(
                for: available, minimum: Tokens.Layout.artistColumnWidth)
            ScrollView {
                // Flat and alphabetical, not shelved by initial — see issue #51.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(),
                                                       spacing: Tokens.Space.xl),
                                   count: columns),
                    alignment: .leading,
                    spacing: Tokens.Space.xxl
                ) {
                    ForEach(model.artists) { artist in
                        ArtistCard(artist: artist)
                    }
                }
                .padding(.horizontal, Tokens.Space.contentInset)
                .padding(.top, Tokens.Space.xl)
                .padding(.bottom, 40)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct ArtistCard: View {
    @Environment(AppModel.self) private var model
    var artist: Artist
    @State private var isHovering = false

    var body: some View {
        // The artist screen, not the first album that happens to match — an
        // artist with ten records had nine of them unreachable from here.
        Button { model.show(.artist(artist.name)) } label: {
            VStack(spacing: 11) {
                ArtworkView(artworkID: model.artworkID(forArtist: artist.name),
                            isCircular: true,
                            displaySize: 200)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)

                VStack(spacing: 3) {
                    Text(artist.name)
                        // Two lines, then truncation: holding the second line
                        // open put a visible gap under every one-line name.
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Color(hex: 0xEBEBF0))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(artist.summary)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .opacity(isHovering ? 0.86 : 1)
        }
        .plainControl()
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(artist.name), \(artist.summary)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Albums

/// How many cards of at least `minimum` points fit across `width`, never fewer
/// than one. Shared by both grids so they wrap at the same rhythm.
enum GridMetrics {
    static func columnCount(for width: CGFloat, minimum: CGFloat,
                            spacing: CGFloat = Tokens.Space.xl) -> Int {
        guard width > 0, minimum > 0 else { return 1 }
        return max(1, Int((width + spacing) / (minimum + spacing)))
    }
}

/// The album grid, optionally under a header that scrolls away with it — the
/// artist screen puts its name and counts there.
struct AlbumGrid<Header: View>: View {
    @Environment(AppModel.self) private var model
    var albums: [Album]
    var subtitle: AlbumCard.Subtitle = .artist
    @ViewBuilder var header: Header

    var body: some View {
        // The column count is computed rather than left to
        // `GridItem(.adaptive(minimum:))`. Adaptive columns cost a full layout
        // pass over every item to decide how many fit, which stops LazyVGrid
        // being lazy at all: at 2,500 albums a single scrolled frame took 1.6
        // seconds. Fixed columns keep it to the rows on screen.
        GeometryReader { geometry in
            let available = geometry.size.width - Tokens.Space.contentInset * 2
            let columns = GridMetrics.columnCount(for: available,
                                                  minimum: model.albumColumnWidth)
            ScrollView {
                header
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(),
                                                       spacing: Tokens.Space.xl),
                                   count: columns),
                    alignment: .leading,
                    spacing: Tokens.Space.xxl
                ) {
                    ForEach(albums) { album in
                        AlbumCard(album: album, subtitle: subtitle)
                    }
                }
                .padding(.horizontal, Tokens.Space.contentInset)
                .padding(.vertical, Tokens.Space.xxl)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

extension AlbumGrid where Header == EmptyView {
    init(albums: [Album]) {
        self.init(albums: albums, subtitle: .artist, header: { EmptyView() })
    }
}

struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var album: Album
    /// What the second line says. The library grid names the artist; an
    /// artist's own page already knows who they are, and needs the year to
    /// tell a record from its remaster.
    var subtitle: Subtitle = .artist
    @State private var isHovering = false
    /// Where the pointer last was inside this card, and how big the card is —
    /// between them they place the drag chip. See `anchored(in:at:)`.
    @State private var pointer: CGPoint = .zero
    @State private var cardSize: CGSize = .zero

    enum Subtitle { case artist, year }

    private var subtitleText: String {
        switch subtitle {
        case .artist: album.albumArtist
        case .year: album.year.map(String.init) ?? "Year unknown"
        }
    }

    var body: some View {
        Button { model.show(.album(album.key)) } label: {
            VStack(alignment: .leading, spacing: 11) {
                ArtworkView(artworkID: album.artworkID,
                            cornerRadius: Tokens.Radius.control,
                            caption: album.artworkID == nil ? "NO COVER ART" : "COVER ART",
                            displaySize: 320)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Color(hex: 0xEBEBF0))
                        // Two lines, so a long title truncates predictably
                        // rather than pushing the grid rows out of alignment.
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Text(subtitleText)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .opacity(isHovering ? 0.86 : 1)
        }
        .plainControl()
        .onHover { isHovering = $0 }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { cardSize = geometry.size }
                    .onChange(of: geometry.size) { _, new in cardSize = new }
            }
        }
        .onContinuousHover { phase in
            if case .active(let point) = phase { pointer = point }
        }
        // A whole record onto a playlist row, in album order. Anchored the
        // same way the track rows are, or the chip slides in from the middle
        // of the cover to reach the pointer.
        .draggable(TrackSelection(album.discs.flatMap(\.tracks))) {
            TrackDragPreview.album(album).anchored(in: cardSize, at: pointer)
        }
        .cadenceContextMenu {
            PlaylistMenu.album(album, model: model, playback: playback)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var spokenLabel: String {
        var parts = [album.title, album.albumArtist]
        if let year = album.year { parts.append(String(year)) }
        if album.hasMultipleDiscs { parts.append("\(album.discCount) discs") }
        if album.isCompilation { parts.append("Compilation") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Playlists

/// A library can have no playlists for a long time — the shelf should say so
/// and offer the one thing to do about it, rather than showing an empty pane.
private struct PlaylistsEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyState(
            systemImage: "list.bullet",
            title: "No playlists yet",
            message: "A playlist is your own running order.\nMake one, then drop tracks into it as you go."
        ) {
            CapsuleButton(title: "New Playlist", systemImage: "plus", kind: .filled) {
                model.naming = .create(seed: [])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.surface)
    }
}

private struct PlaylistList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVStack(spacing: Tokens.Space.xxs) {
            ForEach(model.playlists) { playlist in
                PlaylistShelfRow(playlist: playlist)
            }
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.top, Tokens.Space.xl)
        .padding(.bottom, 44)
    }
}

private struct PlaylistShelfRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var playlist: Playlist

    @State private var isTargeted = false

    var body: some View {
        // Opening it is what clicking a playlist has to do; that it did
        // nothing here was half of issue #1.
        Button { model.show(.playlist(playlist.id)) } label: {
            HStack(spacing: Tokens.Space.l) {
                ArtworkView(artworkID: artworkID, cornerRadius: 5, displaySize: 64)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(Tokens.Typography.sans(14, .bold))
                        .foregroundStyle(Color(hex: 0xEAEAEF))
                    Text(playlist.summary)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
                Spacer(minLength: Tokens.Space.l)
                Text(DurationFormat.approximate(playlist.duration))
                    .font(Tokens.Typography.mono(11))
                    .foregroundStyle(Tokens.Palette.textFaint)
            }
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, 10)
            .hoverHighlight(isActive: isTargeted, radius: Tokens.Radius.card)
            .contentShape(Rectangle())
        }
        .plainControl()
        .dropDestination(for: TrackSelection.self) { selections, _ in
            let ids = selections.flatMap(\.trackIDs)
            guard !ids.isEmpty else { return false }
            Task { await model.addTracks(ids, to: playlist.id) }
            return true
        } isTargeted: { isTargeted = $0 }
        .cadenceContextMenu {
            PlaylistMenu.actions(model: model, playback: playback, playlist: playlist)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(playlist.name), \(playlist.summary), "
            + DurationFormat.approximate(playlist.duration))
        .accessibilityAddTraits(.isButton)
    }

    private var artworkID: Artwork.ID? {
        model.tracks(in: playlist).compactMap(\.artworkID).first
    }
}
