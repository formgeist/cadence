import SwiftUI
import CadenceCore

/// Full-window artwork with the transport hidden until the pointer moves into
/// the frame. Not in PLAN.md's phase list — it comes from the design canvas,
/// and belongs to the design pass.
struct ImmersiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    @State private var isHovering = false

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Tokens.Palette.immersiveTop, location: 0),
                    .init(color: Color(hex: 0x0B0B0D), location: 0.55),
                    .init(color: Tokens.Palette.immersiveBottom, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                artworkStage
            }
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack {
            Color.clear.frame(width: Tokens.Layout.trafficLightInset, height: 1)
            Wordmark(isPlaying: playback.isPlaying)
            Spacer()
            Button { model.isImmersive = false } label: {
                Text("Close")
                    .font(Tokens.Typography.sans(13, .semibold))
                    .foregroundStyle(Color(hex: 0x7D7D88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .plainControl()
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, Tokens.Space.l)
        .frame(height: 44)
    }

    private var artworkStage: some View {
        ZStack {
            ArtworkView(
                artworkID: playback.currentTrack?.artworkID,
                cornerRadius: 12,
                caption: "ALBUM ARTWORK\n1400 × 1400",
                captionSize: 11,
                stripe: 10,
                displaySize: 600,
                accessibilityLabel: playback.currentTrack.map {
                    "Artwork for \($0.albumTitle)"
                }
            )
            .frame(width: Tokens.Layout.immersiveArt, height: Tokens.Layout.immersiveArt)
            .shadow(color: .black.opacity(0.72), radius: 55, y: 30)
            // The art lifts and shrinks to make room for the controls, rather
            // than having them sit on top of it.
            .scaleEffect(isHovering ? 0.87 : 1)
            .offset(y: isHovering ? -52 : 0)
            .animation(Tokens.Motion.artLift, value: isHovering)

            if let track = playback.currentTrack {
                trackCaption(track)
                formatBadges(track)
            }

            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func trackCaption(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Playing now", size: 10, color: Tokens.Palette.accent)
            Text(track.title)
                .font(Tokens.Typography.immersiveTitle)
                .tracking(-1.1)
                .foregroundStyle(Color(hex: 0xF5F5F9))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            InlineLink(text: track.artist, font: Tokens.Typography.sans(15.5, .semibold),
                       color: Color(hex: 0xB9B9C2)) {
                model.show(.artist(track.artist))
            }
            InlineLink(text: [track.albumTitle, track.year.map(String.init)]
                .compactMap { $0 }.joined(separator: " · "),
                       font: Tokens.Typography.sans(13, .medium),
                       color: Color(hex: 0x6F6F7A)) {
                model.show(.album(track.albumKey))
            }
        }
        // `.combine` swallows the two links' own button semantics along with
        // everything else here, so they come back as named rotor actions.
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Go to artist") { model.show(.artist(track.artist)) }
        .accessibilityAction(named: "Go to album") { model.show(.album(track.albumKey)) }
        .frame(maxWidth: 400, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 56)
        .padding(.bottom, 46)
    }

    private func formatBadges(_ track: Track) -> some View {
        HStack(spacing: Tokens.Space.s) {
            QualityBadge(
                text: track.format.isLossless
                    ? "\(track.format.codec.name) LOSSLESS"
                    : track.format.codec.name,
                emphasis: .accent)
            QualityBadge(text: track.format.longDescription)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 56)
        .padding(.bottom, 46)
    }

    private var controls: some View {
        VStack(spacing: Tokens.Space.l) {
            TransportControls(size: .immersive)

            VStack(spacing: 7) {
                ScrubBar(
                    fraction: playback.progress.fraction,
                    height: 4,
                    accessibilityValue: NowPlayingPane.spokenPosition(playback.progress)
                ) { fraction in
                    playback.seek(toFraction: fraction)
                }
                HStack {
                    Text(playback.progress.elapsedText)
                    Spacer()
                    Text(playback.progress.remainingText)
                }
                .font(Tokens.Typography.mono(10.5))
                .foregroundStyle(Color(hex: 0x6A6A74))
                .monospacedDigit()
                .accessibilityHidden(true)
            }
            .frame(width: 420)
        }
        .padding(.horizontal, Tokens.Space.xxl)
        .padding(.top, Tokens.Space.l)
        .padding(.bottom, 18)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .fill(Color(hex: 0x141419).opacity(0.82))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.panel,
                                                 style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .strokeBorder(Color(hex: 0x2B2B33), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 25, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 34)
        .opacity(isHovering ? 1 : 0)
        .offset(y: isHovering ? 0 : 10)
        .allowsHitTesting(isHovering)
        .animation(Tokens.Motion.controls, value: isHovering)
    }
}
