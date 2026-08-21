import SwiftUI
import CadenceCore

/// The window's own chrome. The mock paints three traffic-light circles; a
/// native window with `.hiddenTitleBar` already has real ones, so this reserves
/// their space instead of drawing imitations.
struct TitleBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        @Bindable var model = model

        HStack(spacing: Tokens.Space.l) {
            Color.clear.frame(width: Tokens.Layout.trafficLightInset, height: 1)

            HStack(spacing: Tokens.Space.xs) {
                NavigationChevron(direction: .backward, isEnabled: model.canGoBack) {
                    model.goBack()
                }
                NavigationChevron(direction: .forward, isEnabled: false) {}
            }

            SearchField()
                .frame(maxWidth: Tokens.Layout.searchFieldMaxWidth)
                .frame(maxWidth: .infinity)
                .zIndex(30)

            // Balances the chevrons so the field sits optically centred.
            Color.clear.frame(width: 92, height: 1)
        }
        .padding(.horizontal, Tokens.Space.l)
        .frame(height: Tokens.Layout.titleBarHeight)
        .background(Tokens.Palette.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: 0x1F1F24))
                .frame(height: 1)
        }
    }
}

private struct NavigationChevron: View {
    enum Direction { case backward, forward }

    var direction: Direction
    var isEnabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .backward ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled
                                 ? (isHovering ? Color(hex: 0xC9C9D2) : Color(hex: 0x6E6E78))
                                 : Color(hex: 0x43434C))
                .frame(width: 26, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .fill(isEnabled && isHovering ? Color(hex: 0x1E1E24) : .clear)
                }
        }
        .plainControl()
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(direction == .backward ? "Back" : "Forward")
    }
}

// MARK: - Search

struct SearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s + 2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x7A7A85))
                    .accessibilityHidden(true)

                TextField("Search artists, albums, tracks", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundStyle(Color(hex: 0xF0F0F5))
                    .focused($isFocused)
                    .onSubmit { isFocused = false }
                    .accessibilityLabel("Search library")

                if !model.searchText.isEmpty {
                    Button {
                        model.endSearch()
                        isFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0x7A7A85))
                    }
                    .plainControl()
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(isFocused
                          ? Tokens.Palette.fieldFocusBackground
                          : Tokens.Palette.fieldBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(isFocused
                                  ? Tokens.Palette.fieldFocusBorder
                                  : Tokens.Palette.fieldBorder, lineWidth: 1)
            }
        }
        .overlay(alignment: .top) {
            if isFocused, !model.searchText.isEmpty {
                SearchResultsPopover(onPick: { isFocused = false })
                    .offset(y: 38)
            }
        }
        .onChange(of: isFocused) { _, focused in
            model.isSearching = focused
        }
        .onExitCommand {
            model.endSearch()
            isFocused = false
        }
    }
}

private struct SearchResultsPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var onPick: () -> Void

    var body: some View {
        let results = model.searchResults

        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text("No results for “\(model.searchText)”")
                    .font(Tokens.Typography.sans(11.5, .semibold))
                    .foregroundStyle(Color(hex: 0x8A8A94))
                    .padding(.horizontal, Tokens.Space.xl)
                    .padding(.vertical, 14)
            } else {
                if let topHit = results.topHit {
                    TopHitRow(album: topHit) { open(topHit) }
                }
                if !results.artists.isEmpty {
                    group("Artists", results.artists.map { artist in
                        Row(title: artist.name,
                            subtitle: artist.albumCount == 1
                                ? "1 album" : "\(artist.albumCount) albums",
                            trailing: artist.formats.first ?? "",
                            isRound: true,
                            action: { open(artist) })
                    })
                }
                if !results.albums.isEmpty {
                    group("Albums", results.albums.map { album in
                        Row(title: album.title,
                            subtitle: [album.albumArtist, album.year.map(String.init)]
                                .compactMap { $0 }.joined(separator: " · "),
                            trailing: album.dominantFormat?.shortDescription ?? "",
                            isRound: false,
                            action: { open(album) })
                    })
                }
                if !results.tracks.isEmpty {
                    group("Tracks", results.tracks.map { track in
                        Row(title: track.title,
                            subtitle: track.albumTitle,
                            trailing: DurationFormat.clock(track.duration),
                            isRound: false,
                            action: { play(track) })
                    })
                }

                Divider().overlay(Color(hex: 0x24242B)).padding(.top, Tokens.Space.s)
                HStack {
                    Text("See all results for “\(model.searchText)”")
                        .font(Tokens.Typography.sans(11.5, .semibold))
                        .foregroundStyle(Color(hex: 0x8A8A94))
                    Spacer()
                    Text("↵")
                        .font(Tokens.Typography.mono(10))
                        .foregroundStyle(Tokens.Palette.textFaint)
                }
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.vertical, 9)
            }
        }
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .fill(Tokens.Palette.popover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .strokeBorder(Tokens.Palette.popoverBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
    }

    private struct Row: Identifiable {
        var id = UUID()
        var title: String
        var subtitle: String
        var trailing: String
        var isRound: Bool
        var action: () -> Void
    }

    @ViewBuilder
    private func group(_ label: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(label, size: 9.5)
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.top, Tokens.Space.m)
                .padding(.bottom, 6)
            ForEach(rows) { row in
                Button(action: row.action) {
                    HStack(spacing: Tokens.Space.m) {
                        ArtworkView(artworkID: nil,
                                    cornerRadius: 3,
                                    isCircular: row.isRound,
                                    stripe: 4,
                                    displaySize: 32)
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .font(Tokens.Typography.sans(12.5, .semibold))
                                .foregroundStyle(Color(hex: 0xDCDCE3))
                                .lineLimit(1)
                            Text(row.subtitle)
                                .font(Tokens.Typography.sans(10.5, .medium))
                                .foregroundStyle(Color(hex: 0x6A6A74))
                                .lineLimit(1)
                        }
                        Spacer(minLength: Tokens.Space.s)
                        Text(row.trailing)
                            .font(Tokens.Typography.mono(10))
                            .foregroundStyle(Tokens.Palette.textFaint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .hoverHighlight(radius: Tokens.Radius.control,
                                    hoverColor: Color(hex: 0x1F1F26))
                    .padding(.horizontal, 6)
                }
                .plainControl()
            }
        }
    }

    private func open(_ album: Album) {
        model.show(.album(album.key))
        model.endSearch()
        onPick()
    }

    private func open(_ artist: Artist) {
        model.show(.artist(artist.name))
        model.endSearch()
        onPick()
    }

    private func play(_ track: Track) {
        guard let album = model.album(for: track.albumKey) else { return }
        playback.play(track, in: album.discs.flatMap(\.tracks))
        model.endSearch()
        onPick()
    }
}

private struct TopHitRow: View {
    var album: Album
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.m) {
                ArtworkView(artworkID: album.artworkID, cornerRadius: Tokens.Radius.thumb,
                                displaySize: 48)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(Tokens.Typography.sans(13, .bold))
                        .foregroundStyle(Color(hex: 0xF1F1F5))
                        .lineLimit(1)
                    Text([("Album"), album.albumArtist, album.year.map(String.init)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Tokens.Typography.sans(11, .medium))
                        .foregroundStyle(Color(hex: 0x7C7C86))
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.Space.s)
                Text("TOP HIT")
                    .font(Tokens.Typography.mono(9.5, .medium))
                    .tracking(0.8)
                    .foregroundStyle(Tokens.Palette.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .fill(Color(hex: 0x1F1F26))
            }
            .padding(.horizontal, 6)
        }
        .plainControl()
    }
}
