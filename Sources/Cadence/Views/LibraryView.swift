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
            ScrollView {
                switch model.tab {
                case .artists: ArtistsList()
                case .albums: AlbumGrid()
                case .playlists: PlaylistList()
                }
            }
            .scrollContentBackground(.hidden)
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

            Button { zoom = min(1, zoom + 0.25) } label: {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(hex: 0x6A6A74), lineWidth: 1.2)
                    .frame(width: 14, height: 14)
            }
            .plainControl()
        }
    }
}

// MARK: - Artists

private struct ArtistsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
            ForEach(model.artistSections) { section in
                HStack(spacing: 14) {
                    Text(section.letter)
                        .font(Tokens.Typography.mono(12, .medium))
                        .tracking(1.2)
                        .foregroundStyle(Tokens.Palette.accent)
                    Rectangle().fill(Tokens.Palette.separator).frame(height: 1)
                }
                .padding(.horizontal, Tokens.Space.contentInset)
                .padding(.top, Tokens.Space.xl)
                .padding(.bottom, Tokens.Space.s)

                ForEach(section.artists) { artist in
                    ArtistRow(artist: artist)
                }
            }
        }
        .padding(.top, Tokens.Space.s)
        .padding(.bottom, 40)
    }
}

private struct ArtistRow: View {
    @Environment(AppModel.self) private var model
    var artist: Artist

    var body: some View {
        Button {
            if let album = model.albums.first(where: { $0.albumArtist == artist.name }) {
                model.show(.album(album.key))
            }
        } label: {
            HStack(spacing: 14) {
                ArtworkView(artworkID: nil, isCircular: true)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.name)
                        .font(Tokens.Typography.rowTitle)
                        .foregroundStyle(Color(hex: 0xEAEAEF))
                        .lineLimit(1)
                    Text(artist.summary)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
                Spacer(minLength: Tokens.Space.l)
                Text(artist.formatSummary)
                    .font(Tokens.Typography.mono(11))
                    .foregroundStyle(Tokens.Palette.textFaint)
            }
            .padding(.horizontal, Tokens.Space.contentInset)
            .padding(.vertical, 9)
            .hoverHighlight(radius: 0)
        }
        .plainControl()
    }
}

// MARK: - Albums

private struct AlbumGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: model.albumColumnWidth),
                               spacing: Tokens.Space.xl)],
            alignment: .leading,
            spacing: Tokens.Space.xxl
        ) {
            ForEach(model.albums) { album in
                AlbumCard(album: album)
            }
        }
        .padding(.horizontal, Tokens.Space.contentInset)
        .padding(.vertical, Tokens.Space.xxl)
    }
}

private struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    var album: Album
    @State private var isHovering = false

    var body: some View {
        Button { model.show(.album(album.key)) } label: {
            VStack(alignment: .leading, spacing: 11) {
                ArtworkView(artworkID: album.artworkID,
                            cornerRadius: Tokens.Radius.control,
                            caption: album.artworkID == nil ? "NO COVER ART" : "COVER ART")
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
                    Text(album.albumArtist)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .opacity(isHovering ? 0.86 : 1)
        }
        .plainControl()
        .onHover { isHovering = $0 }
    }
}

// MARK: - Playlists

private struct PlaylistList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVStack(spacing: Tokens.Space.xxs) {
            ForEach(model.playlists) { playlist in
                HStack(spacing: Tokens.Space.l) {
                    ArtworkView(artworkID: nil, cornerRadius: 5)
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
                .hoverHighlight(radius: Tokens.Radius.card)
            }
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.top, Tokens.Space.xl)
        .padding(.bottom, 44)
    }
}
