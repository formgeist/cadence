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
        // The grid brings the scroll view; the header rides inside it so it
        // scrolls away rather than pinning a 200pt band over the covers.
        AlbumGrid(albums: albums, subtitle: .year) { header }
            .background(Tokens.Palette.surface)
    }

    private var header: some View {
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
