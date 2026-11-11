import SwiftUI
import CadenceCore

// MARK: - Grid

/// Nothing to show until a catalog is made, so the empty shelf says what one
/// is and offers to make the first.
struct CatalogsEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyState(
            systemImage: "books.vertical",
            title: "No catalogs yet",
            message: "A catalog gathers albums by rules — a label, a decade, a format.\nIt keeps itself up to date as your library changes."
        ) {
            CapsuleButton(title: "New Catalog", systemImage: "plus", kind: .filled) {
                model.editingCatalog = .create
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.surface)
    }
}

struct CatalogGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        CardGrid(items: model.catalogs,
                 columnWidth: model.albumColumnWidth,
                 scrollAnchor: $model.catalogGridScrollAnchor,
                 typeAheadKey: \.name,
                 open: { model.show(.catalog($0.id)) },
                 header: { EmptyView() }) { catalog, _, isFocused, onSelect in
            CatalogCard(catalog: catalog, isKeyboardFocused: isFocused, onSelect: onSelect)
        }
    }
}

/// A catalog has no cover of its own; it tiles its first four albums' — see
/// `CoverMosaic`.
struct CatalogArtwork: View {
    @Environment(AppModel.self) private var model
    var catalog: Catalog
    var cornerRadius: CGFloat = Tokens.Radius.control
    var displaySize: Int = 320

    var body: some View {
        CoverMosaic(artworkIDs: model.coverIDs(forCatalog: catalog),
                    cornerRadius: cornerRadius, displaySize: displaySize)
    }
}

extension Catalog {
    /// `12 albums`
    func albumSummary(count: Int) -> String {
        count == 1 ? "1 album" : "\(count) albums"
    }
}

/// One catalog in the grid: tiled covers, name, album count. Not a `Button`,
/// for the reason `PlaylistCard` is not — the hover Play button is a button of
/// its own.
private struct CatalogCard: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var catalog: Catalog
    var isKeyboardFocused: Bool = false
    var onSelect: () -> Void = {}

    @State private var isHovering = false
    @State private var isHoveringArt = false
    @State private var isHoveringPlay = false

    private var albums: [Album] { model.albums(inCatalog: catalog.id) }
    private var detail: String { catalog.albumSummary(count: albums.count) }

    private func open() {
        onSelect()
        model.show(.catalog(catalog.id))
    }

    private func play() {
        let tracks = CatalogMenu.tracks(of: albums)
        guard let first = tracks.first else { return }
        playback.play(first, in: tracks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            CatalogArtwork(catalog: catalog)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if isHoveringArt && !albums.isEmpty {
                        playOverlay.transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: isHoveringArt)
                .onHover { hovering in
                    isHoveringArt = hovering
                    // The button leaves with the hover, often before its
                    // own exit fires.
                    if !hovering { isHoveringPlay = false }
                }
                .keyboardFocusRing(isKeyboardFocused,
                                  in: RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                       style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(catalog.name)
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Color(hex: 0xEBEBF0))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(isHovering && !isHoveringPlay ? 0.86 : 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .onTapGesture(perform: open)
        .cadenceContextMenu {
            CatalogMenu.actions(model: model, playback: playback, catalog: catalog)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(catalog.name), \(detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Play", play)
    }

    private var playOverlay: some View {
        CoverPlayButton(subject: catalog.name, isHovered: $isHoveringPlay, action: play)
    }
}

// MARK: - Menu

/// The verbs a catalog offers, shared by its card's context menu and the ⋯ on
/// its page.
enum CatalogMenu {
    /// Album order, each record's discs in order, so Play works through the
    /// shelf the way the screen reads.
    static func tracks(of albums: [Album]) -> [Track] {
        albums.flatMap { $0.discs.flatMap(\.tracks) }
    }

    @MainActor
    static func actions(model: AppModel, playback: PlaybackController,
                        catalog: Catalog, includeSort: Bool = false) -> [MenuItem] {
        let tracks = tracks(of: model.albums(inCatalog: catalog.id))
        let hasTracks = !tracks.isEmpty
        var items: [MenuItem] = [
            .action("Play", PlaylistMenu.Symbol.play, enabled: hasTracks) {
                if let first = tracks.first { playback.play(first, in: tracks) }
            },
            .action("Shuffle", PlaylistMenu.Symbol.shuffle, enabled: hasTracks) {
                playback.shuffle(tracks)
            },
            .action("Add to Queue", PlaylistMenu.Symbol.addToQueue, enabled: hasTracks) {
                playback.appendToQueue(tracks)
            },
            .separator,
        ]
        if includeSort {
            let current = model.catalog(id: catalog.id)?.definition.sort ?? catalog.definition.sort
            items.append(.submenu("Sort By", "slider.horizontal.3", items: CatalogSort.allCases.map { sort in
                .choice(sort.label, isOn: current == sort) {
                    Task { await model.setSort(sort, forCatalog: catalog) }
                }
            }))
        }
        items.append(.action("Edit Rules…", "books.vertical") {
            model.editingCatalog = .edit(model.catalog(id: catalog.id) ?? catalog)
        })
        items.append(.action("Rename…", PlaylistMenu.Symbol.rename) {
            model.naming = .renameCatalog(model.catalog(id: catalog.id) ?? catalog)
        })
        items.append(.separator)
        items.append(.action("Delete", PlaylistMenu.Symbol.delete, destructive: true) {
            model.catalogPendingDeletion = catalog
        })
        return items
    }
}

// MARK: - Detail

/// One catalog's albums, laid out like a genre page: a header, then the cover
/// grid or each record with its tracklist.
struct CatalogDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var catalog: Catalog

    private var albums: [Album] { model.albums(inCatalog: catalog.id) }
    private var orderedTracks: [Track] { CatalogMenu.tracks(of: albums) }

    private var isLoaded: Bool {
        guard let id = playback.currentTrack?.id else { return false }
        return orderedTracks.contains { $0.id == id }
    }

    private var isPlaying: Bool { isLoaded && playback.isPlaying }

    var body: some View {
        @Bindable var model = model

        Group {
            if albums.isEmpty {
                VStack(spacing: 0) {
                    header
                    noMatches
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                switch model.catalogAlbumLayout {
                case .grid:
                    AlbumGrid(albums: albums, subtitle: .artist,
                              scrollAnchor: $model.catalogAlbumGridScrollAnchor) { header }
                case .list:
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            header
                            ForEach(albums) { album in
                                AlbumSection(album: album, showsArtist: true)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .background(Tokens.Palette.surface)
    }

    private var noMatches: some View {
        VStack(spacing: Tokens.Space.m) {
            Text("No albums match these rules")
                .font(Tokens.Typography.sans(14, .semibold))
                .foregroundStyle(Tokens.Palette.textSecondary)
            Text("Albums appear here as soon as your library has some that fit.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
            CapsuleButton(title: "Edit Rules", systemImage: "pencil") {
                model.editingCatalog = .edit(catalog)
            }
            .padding(.top, Tokens.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var summary: String {
        let duration = albums.reduce(0) { $0 + $1.duration }
        let tracks = albums.reduce(0) { $0 + $1.trackCount }
        return [catalog.albumSummary(count: albums.count),
                tracks == 1 ? "1 track" : "\(tracks) tracks",
                DurationFormat.approximate(duration)].joined(separator: " · ")
    }

    private var header: some View {
        @Bindable var model = model

        return
        HStack(alignment: .bottom, spacing: 32) {
            CatalogArtwork(catalog: catalog, cornerRadius: Tokens.Radius.card)
                .frame(width: Tokens.Layout.artistHeaderArt,
                       height: Tokens.Layout.artistHeaderArt)
                .shadow(color: .black.opacity(0.55), radius: 25, y: 12)

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Catalog")

                Text(catalog.name)
                    .font(Tokens.Typography.sans(38, .heavy))
                    .tracking(Tokens.Typography.Tracking.display)
                    .foregroundStyle(Color(hex: 0xF4F4F8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(catalog.definition.summary)
                        .font(Tokens.Typography.sans(13.5, .semibold))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(2)
                    Text(summary)
                        .font(Tokens.Typography.sans(13.5, .medium))
                        .foregroundStyle(Color(hex: 0x82828D))
                }

                HStack(spacing: 10) {
                    PlayPauseButton(isPlaying: isPlaying, subject: catalog.name) {
                        if isLoaded {
                            playback.togglePlayPause()
                        } else if let first = orderedTracks.first {
                            playback.play(first, in: orderedTracks)
                        }
                    }
                    .disabled(orderedTracks.isEmpty)
                    CapsuleButton(title: "Shuffle") {
                        playback.shuffle(orderedTracks)
                    }
                    .disabled(orderedTracks.isEmpty)
                    CapsuleButton(title: "Edit Rules", systemImage: "pencil") {
                        model.editingCatalog = .edit(catalog)
                    }
                    MenuButton(systemImage: "ellipsis",
                               accessibilityLabel: "More actions for \(catalog.name)") {
                        CatalogMenu.actions(model: model, playback: playback,
                                            catalog: catalog, includeSort: true)
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !albums.isEmpty {
                AlbumLayoutPicker(layout: $model.catalogAlbumLayout)
            }
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
}
