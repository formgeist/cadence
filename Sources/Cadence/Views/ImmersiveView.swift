import SwiftUI
import CadenceCore

/// Full-window artwork with the transport hidden until the pointer moves into
/// the frame. Not in PLAN.md's phase list — it comes from the design canvas,
/// and belongs to the design pass.
struct ImmersiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @Environment(ArtworkLoader.self) private var artworkLoader

    @State private var isHovering = false

    private var bloom: (primary: Color, secondary: Color) {
        artworkLoader.bloomColors(for: playback.currentTrack?.artworkID)
            ?? (Tokens.Palette.accent, Color(hex: 0x4C2A8C))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundLayer

            VStack(spacing: 0) {
                topBar
                VStack(spacing: 0) {
                    stage
                    band
                }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
            }

            bottomScrim
        }
        .transition(.opacity)
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Tokens.Palette.immersiveTop, location: 0),
                    .init(color: Color(hex: 0x0B0B0D), location: 0.55),
                    .init(color: Tokens.Palette.immersiveBottom, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            AmbientBloom(primary: bloom.primary, secondary: bloom.secondary)
        }
        .ignoresSafeArea()
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

    /// Flexible: it takes whatever height is left once the top bar and the
    /// bottom band — fixed regardless of hover — have theirs, so the artwork
    /// centers in the true remaining space instead of needing a hover-time
    /// nudge to clear the controls. The artwork itself shrinks below its
    /// usual 540pt when that space is tight, rather than overflowing into
    /// the band below on the app's smallest supported window.
    private var stage: some View {
        GeometryReader { geometry in
            let side = min(
                Tokens.Layout.immersiveArt,
                geometry.size.width - 48,
                geometry.size.height - 48)

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
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.72), radius: 55, y: 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var band: some View {
        HStack(alignment: .bottom, spacing: 24) {
            Group {
                if let track = playback.currentTrack { trackCaption(track) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            controls

            Group {
                if let track = playback.currentTrack { formatBadges(track) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 56)
        .padding(.bottom, 40)
        .frame(height: Tokens.Layout.immersiveBandHeight)
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
        .frame(maxWidth: 350, alignment: .leading)
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
        .opacity(isHovering ? 1 : 0)
        .offset(y: isHovering ? 0 : 10)
        .allowsHitTesting(isHovering)
        .animation(Tokens.Motion.controls, value: isHovering)
    }

    /// Legibility for the caption and badges, which — unlike the transport
    /// controls — stay visible whether or not the pointer is hovering.
    private var bottomScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.46), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

/// Two soft, slowly drifting glows lifted from the corners of the current
/// cover, blurred into the immersive background — the room's light shifts
/// with the track instead of staying the same flat gradient for every album.
private struct AmbientBloom: View {
    var primary: Color
    var secondary: Color

    @State private var drift = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RadialGradient(
                    colors: [primary.opacity(0.55), .clear],
                    center: .center, startRadius: 0, endRadius: min(size.width, size.height) * 0.42
                )
                .frame(width: size.width, height: size.height)
                .position(x: size.width * (drift ? 0.285 : 0.30),
                          y: size.height * (drift ? 0.26 : 0.24))

                RadialGradient(
                    colors: [secondary.opacity(0.42), .clear],
                    center: .center, startRadius: 0, endRadius: min(size.width, size.height) * 0.46
                )
                .frame(width: size.width, height: size.height)
                .position(x: size.width * (drift ? 0.735 : 0.74),
                          y: size.height * (drift ? 0.64 : 0.66))
            }
        }
        .blur(radius: 90)
        .opacity(0.85)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 26).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}
