import SwiftUI
import CadenceCore
import CadenceDesign

/// Whether the playing track shows as the Now Playing panel down the right
/// of the window, or as the mini player floating over the library's
/// bottom-right corner, which leaves the library the full width. Remembered
/// across launches; the title bar's panel button and View ▸ Use Mini Player
/// switch it.
enum NowPlayingLayout {
    static let usesMiniPlayerKey = "nowPlaying.usesMiniPlayer"
}

/// The playing track in a capsule floating over the library, as the iPad
/// app has it: the cover, the title and artist with a thin line for how far
/// into the track it is, and previous, play/pause and next. The
/// cover opens full-screen artwork; the title the album, the artist the
/// artist. The panel button brings the Now Playing panel back.
struct FloatingMiniPlayer: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @AppStorage(NowPlayingLayout.usesMiniPlayerKey) private var usesMiniPlayer = false

    static let width: CGFloat = 410
    static let height: CGFloat = 56
    /// Room kept under the library so its last rows scroll clear of the
    /// player: its height and the margin under it.
    static let clearance: CGFloat = height + margin + 8
    static let margin: CGFloat = 20
    /// The cover is square in a capsule: 36pt set 10 in from the round end
    /// keeps its corners inside the curve instead of cut off by it.
    private static let coverSide: CGFloat = 36
    private static let coverInset: CGFloat = 10

    var body: some View {
        if let track = playback.currentTrack {
            HStack(spacing: 12) {
                Button { model.isImmersive = true } label: {
                    ArtworkView(artworkID: track.artworkID, stripe: 4, displaySize: 80)
                        .frame(width: Self.coverSide, height: Self.coverSide)
                }
                .plainControl()
                .accessibilityLabel("Artwork for \(track.albumTitle)")
                .accessibilityHint("Opens full-screen artwork")
                .help("Full-Screen Artwork")

                VStack(alignment: .leading, spacing: 2) {
                    // A long title scrolls to its end and back rather than
                    // being cut short, as in the iPhone app.
                    Button { model.show(.album(track.albumKey)) } label: {
                        MarqueeText(text: track.title, font: Tokens.Typography.sans(13, .semibold))
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .contentShape(Rectangle())
                    }
                    .plainControl()
                    .accessibilityHint("Opens the album")
                    .help("Go to Album")
                    InlineLink(text: track.artist, font: Tokens.Typography.sans(11.5, .medium),
                               color: Tokens.Palette.textSecondary) {
                        model.show(.artist(track.artist))
                    }
                    ProgressLine(fraction: playback.progress.fraction)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 2) {
                    IconButton(systemImage: "backward.fill", label: "Previous Track",
                               glyphSize: 13, side: 30,
                               restingColor: Tokens.Palette.textPrimary) {
                        playback.previous()
                    }
                    IconButton(systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                               label: playback.isPlaying ? "Pause" : "Play",
                               glyphSize: 15, side: 32,
                               restingColor: Tokens.Palette.textPrimary) {
                        playback.togglePlayPause()
                    }
                    IconButton(systemImage: "forward.fill", label: "Next Track",
                               glyphSize: 13, side: 30,
                               restingColor: Tokens.Palette.textPrimary) {
                        playback.next()
                    }
                    IconButton(systemImage: "sidebar.right", label: "Show Now Playing Panel",
                               glyphSize: 13, side: 30) {
                        usesMiniPlayer = false
                    }
                }
            }
            .padding(.leading, Self.coverInset)
            .padding(.trailing, 12)
            .frame(width: Self.width, height: Self.height)
            .modifier(MiniPlayerSurface())
        }
    }
}

/// How far into the track it is, as a thin line. Only an indication:
/// seeking is the panel's scrub bar's job, so it takes no clicks and says
/// nothing aloud (the transport already names the track).
private struct ProgressLine: View {
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.white.opacity(0.14))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Tokens.Palette.accent)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// Liquid Glass on macOS 26, as the menu bar panel has it; the popover
/// surface with its border and shadow before that.
private struct MiniPlayerSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        } else {
            content
                .background(Tokens.Palette.popover, in: Capsule())
                .overlay(Capsule().strokeBorder(Tokens.Palette.popoverBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        }
    }
}
