import SwiftUI
import CadenceCore

/// "Similar artists" at the foot of an artist page: library artists most like
/// this one, each captioned with why, and — when Last.fm is on — the ones
/// Last.fm suggests that the library does not have.
struct SimilarArtistsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscoveryController.self) private var discovery

    var artist: String
    var inset: CGFloat = Tokens.Space.contentInset

    @State private var results: DiscoveryController.ArtistResults?

    /// Two rows' worth at the default zoom is enough to be a suggestion
    /// without becoming a second artists screen.
    static let limit = 10

    private struct Inputs: Equatable {
        var artist: String
        var usesLastFM: Bool
        var lastFMRevision: Int
        var generation: Int
    }

    var body: some View {
        // A stack, not a `Group`: modifiers on a `Group` attach to its
        // children, and before the first results there are none — so the
        // `.task` that fetches them would never run.
        VStack(spacing: 0) {
            if let results, !(results.inLibrary.isEmpty && results.elsewhere.isEmpty) {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    SimilarSectionHeader(title: "Similar artists")
                    if !results.inLibrary.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: model.albumColumnWidth * 0.8),
                                               spacing: Tokens.Space.xl, alignment: .top)],
                            alignment: .leading,
                            spacing: Tokens.Space.xxl
                        ) {
                            ForEach(results.inLibrary) { similar in
                                SimilarArtistCard(similar: similar)
                            }
                        }
                    }
                    if !results.elsewhere.isEmpty {
                        ElsewhereRow(artists: results.elsewhere)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.top, Tokens.Space.l)
                .padding(.bottom, 44)
            }
        }
        .task(id: Inputs(artist: artist, usesLastFM: discovery.usesLastFM,
                         lastFMRevision: discovery.lastFMRevision,
                         generation: model.libraryGeneration)) {
            let found = await discovery.similarArtists(to: artist, limit: Self.limit)
            guard !Task.isCancelled else { return }
            results = found
        }
    }
}

/// "You might also like" under an album: records by other artists, each with
/// the reason it was picked.
struct SimilarAlbumsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscoveryController.self) private var discovery

    var album: Album.Key
    var inset: CGFloat = Tokens.Space.albumInset

    @State private var results: [SimilarAlbum]?

    static let limit = 10

    private struct Inputs: Equatable {
        var album: Album.Key
        var usesLastFM: Bool
        var lastFMRevision: Int
        var generation: Int
    }

    private var albums: [(Album, SimilarAlbum)] {
        (results ?? []).compactMap { similar in
            model.album(for: similar.key).map { ($0, similar) }
        }
    }

    var body: some View {
        // A stack, not a `Group`: modifiers on a `Group` attach to its
        // children, and before the first results there are none — so the
        // `.task` that fetches them would never run.
        VStack(spacing: 0) {
            if !albums.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    SimilarSectionHeader(title: "You might also like")
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: model.albumColumnWidth),
                                           spacing: Tokens.Space.xl, alignment: .top)],
                        alignment: .leading,
                        spacing: Tokens.Space.xxl
                    ) {
                        ForEach(Array(albums.enumerated()), id: \.element.0.id) { index, pair in
                            VStack(alignment: .leading, spacing: 4) {
                                AlbumCard(album: pair.0, subtitle: .artist, index: index)
                                    .equatable()
                                ReasonCaption(reason: pair.1.reason)
                            }
                        }
                    }
                }
                .padding(.horizontal, inset)
                .padding(.bottom, 44)
            }
        }
        .task(id: Inputs(album: album, usesLastFM: discovery.usesLastFM,
                         lastFMRevision: discovery.lastFMRevision,
                         generation: model.libraryGeneration)) {
            let found = await discovery.similarAlbums(to: album, limit: Self.limit)
            guard !Task.isCancelled else { return }
            results = found
        }
    }
}

// MARK: - Pieces

/// The same label-and-rule header "More from …" uses on the album page.
private struct SimilarSectionHeader: View {
    var title: String

    var body: some View {
        HStack(spacing: 14) {
            SectionLabel(title, size: 10, color: Tokens.Palette.textMuted)
            Rectangle().fill(Tokens.Palette.separator).frame(height: 1)
        }
    }
}

/// Why a card is here, one line under it. The full text is in the tooltip
/// for a long credit name that truncates.
private struct ReasonCaption: View {
    var reason: SimilarityReason

    var body: some View {
        Text(reason.text)
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Palette.textMuted)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(reason.text)
            .accessibilityHidden(true)
    }
}

/// A library artist on the similar list: the round picture the artists screen
/// uses, the name, and the reason in place of the album count.
private struct SimilarArtistCard: View {
    @Environment(AppModel.self) private var model
    var similar: SimilarArtist
    @State private var isHovering = false

    var body: some View {
        Button {
            model.show(.artist(similar.name))
        } label: {
            VStack(spacing: 11) {
                ArtworkView(artworkID: model.artworkID(forArtist: similar.name),
                            isCircular: true,
                            displaySize: 200)
                    .aspectRatio(1, contentMode: .fit)

                VStack(spacing: 3) {
                    Text(similar.name)
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Color(hex: 0xEBEBF0))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(similar.reason.text)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity)
            }
            .opacity(isHovering ? 0.86 : 1)
        }
        .plainControl()
        .focusable(false)
        .animatedHover($isHovering)
        .help(similar.reason.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(similar.name), \(similar.reason.text)")
        .accessibilityHint("Opens the artist page")
        .accessibilityAddTraits(.isButton)
    }
}

/// Last.fm's suggestions the library does not have. Each opens the artist's
/// Last.fm page in the browser — there is nothing in Cadence to open.
private struct ElsewhereRow: View {
    @Environment(\.openURL) private var openURL
    var artists: [ExternalSimilarArtist]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Text("Not in your library · from Last.fm")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Space.s) {
                    ForEach(artists, id: \.name) { artist in
                        // No icon: the glyph set has no "external link"
                        // mark, and the caption above already says where
                        // these go.
                        CapsuleButton(title: artist.name,
                                      accessibilityLabel: "\(artist.name) on Last.fm") {
                            if let url = Self.lastFMURL(for: artist.name) { openURL(url) }
                        }
                        .help("Open \(artist.name) on Last.fm")
                    }
                }
            }
        }
        .padding(.top, Tokens.Space.s)
    }

    /// Last.fm's artist pages put `+` for a space and percent-encode the rest.
    static func lastFMURL(for name: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~ ")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "https://www.last.fm/music/"
                   + encoded.replacingOccurrences(of: " ", with: "+"))
    }
}
