import SwiftUI
import CadenceCore

/// The status item's permanent face — cover art plus who's playing, so a
/// glance at the menu bar answers "what's on" without switching to the window.
struct MenuBarLabel: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(ArtworkLoader.self) private var artwork

    /// MenuBarExtra reads a label image's own `NSImage.size`, not any SwiftUI
    /// `.frame()`/`.resizable()` applied around it — those are silently
    /// ignored on the status item, so the icon must arrive pre-sized and
    /// pre-rounded as a real bitmap.
    private static let iconSide: CGFloat = 18
    /// Baked into the icon bitmap's own width as trailing transparent space —
    /// `.padding()` on the title `Text` is ignored the same way `.frame()` on
    /// the icon was, so the gap has to live in the image's own reported size.
    private static let iconTrailingGap: CGFloat = 4

    /// The status item never clips its label — it grows and pushes other menu
    /// bar items out — so the text is shortened by character count up front.
    /// The title gets the larger share; the artist is usually short anyway.
    private static let maxTitleLength = 28
    private static let maxArtistLength = 18

    private static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    var body: some View {
        if let track = playback.currentTrack {
            Label {
                Text("\(Self.truncated(track.title, to: Self.maxTitleLength)) · \(Self.truncated(track.artist, to: Self.maxArtistLength))")
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(nsImage: icon(for: track))
            }
            .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "music.note")
        }
    }

    private func icon(for track: Track) -> NSImage {
        guard let source = artwork.image(for: track.artworkID, size: Int(Self.iconSide) * 2) else {
            return Self.roundedSquare(side: Self.iconSide, trailingGap: Self.iconTrailingGap) { rect in
                NSColor(white: 0.2, alpha: 1).setFill()
                NSBezierPath(rect: rect).fill()
            }
        }
        return Self.roundedSquare(side: Self.iconSide, trailingGap: Self.iconTrailingGap) { rect in
            let sourceSize = source.size
            let minSide = min(sourceSize.width, sourceSize.height)
            let crop = NSRect(x: (sourceSize.width - minSide) / 2,
                               y: (sourceSize.height - minSide) / 2,
                               width: minSide, height: minSide)
            source.draw(in: rect, from: crop, operation: .copy, fraction: 1)
        }
    }

    /// Bakes a `side`×`side` rounded-rect bitmap onto a canvas that's
    /// `trailingGap` points wider, left fully transparent, so the status item
    /// has no SwiftUI sizing/spacing to ignore — `paint` draws into the
    /// clipped square at the canvas's left edge.
    private static func roundedSquare(side: CGFloat, trailingGap: CGFloat,
                                       paint: (NSRect) -> Void) -> NSImage {
        let output = NSImage(size: NSSize(width: side + trailingGap, height: side))
        output.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
        paint(rect)
        output.unlockFocus()
        return output
    }
}

/// The transport shown when the status item is clicked — play/pause, next
/// and previous, the same three the Playback menu and the dock menu offer.
///
/// On macOS 26 the panel is Liquid Glass: the panel itself is one glass
/// sheet, and the transport sits on it as morphing circular buttons.
struct MenuBarPlaybackView: View {
    @Environment(PlaybackController.self) private var playback

    private static let coverSide: CGFloat = 176

    var body: some View {
        VStack(spacing: Tokens.Space.m) {
            cover
            caption
            transport
        }
        .padding(Tokens.Space.l)
        .frame(width: 208)
        .modifier(PanelSurface())
        // Cadence is dark-only; the panel's material and glass follow suit
        // regardless of the system appearance.
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var cover: some View {
        if let track = playback.currentTrack {
            ArtworkView(artworkID: track.artworkID,
                        cornerRadius: Tokens.Radius.card,
                        displaySize: Int(Self.coverSide))
                .frame(width: Self.coverSide, height: Self.coverSide)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        } else {
            ArtworkPlaceholder()
                .frame(width: Self.coverSide, height: Self.coverSide)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let track = playback.currentTrack {
            VStack(spacing: 2) {
                Text(track.title)
                    .font(Tokens.Typography.trackTitle)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
            }
        } else {
            Text("Not Playing")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    @ViewBuilder
    private var transport: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: Tokens.Space.m) {
                HStack(spacing: Tokens.Space.m) {
                    GlassTransportButton(systemImage: "backward.fill", label: "Previous",
                                         glyphSize: 13, side: 36) { playback.previous() }
                        .disabled(playback.currentTrack == nil)
                    GlassTransportButton(systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                                         label: playback.isPlaying ? "Pause" : "Play",
                                         glyphSize: 17, side: 46) { playback.togglePlayPause() }
                    GlassTransportButton(systemImage: "forward.fill", label: "Next",
                                         glyphSize: 13, side: 36) { playback.next() }
                        .disabled(playback.currentTrack == nil)
                }
            }
        } else {
            HStack(spacing: Tokens.Space.xxl) {
                IconButton(systemImage: "backward.fill", label: "Previous", glyphSize: 13, side: 26) {
                    playback.previous()
                }
                .disabled(playback.currentTrack == nil)

                IconButton(systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                           label: playback.isPlaying ? "Pause" : "Play",
                           glyphSize: 15, side: 30) {
                    playback.togglePlayPause()
                }

                IconButton(systemImage: "forward.fill", label: "Next", glyphSize: 13, side: 26) {
                    playback.next()
                }
                .disabled(playback.currentTrack == nil)
            }
        }
    }
}

/// macOS 26: the whole panel is one sheet of Liquid Glass. `MenuBarExtra`
/// still backs its window with the pre-26 menu material — a heavily blurred,
/// grey-tinted backdrop that makes the panel far murkier than the system's
/// own menu bar panels — and `containerBackground(.clear, for: .window)`
/// does not reach it, so `StockBackdropRemover` hides it from AppKit.
/// Earlier systems keep the flat popover surface the rest of Cadence's
/// popovers use.
private struct PanelSurface: ViewModifier {
    /// Matches the corner radius the window server gives the panel, so the
    /// glass and the window's own outline and shadow share one edge.
    private static let windowCornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: Self.windowCornerRadius))
                .background(StockBackdropRemover())
        } else {
            content.background(Tokens.Palette.popover)
        }
    }
}

/// Hides the menu material `MenuBarExtra` layers behind its content: a
/// `CABackdropLayer` doing the blur, and a near-black sibling composited
/// with a lighten blend that tints it. Both are direct sublayers of the
/// window's hosting view. Matching on the layer's class and blend mode
/// rather than position means an SDK that drops them just finds nothing.
private struct StockBackdropRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RemoverView() }
    func updateNSView(_ view: NSView, context: Context) { (view as? RemoverView)?.strip() }

    private final class RemoverView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            strip()
        }

        override func layout() {
            super.layout()
            strip()
        }

        func strip() {
            guard let layers = window?.contentView?.layer?.sublayers else { return }
            for layer in layers where Self.isStockBackdrop(layer) && !layer.isHidden {
                layer.isHidden = true
            }
        }

        private static func isStockBackdrop(_ layer: CALayer) -> Bool {
            if String(describing: type(of: layer)) == "CABackdropLayer" { return true }
            return (layer.compositingFilter as? String) == "lightenBlendMode"
        }
    }
}

/// A transport glyph on its own disc of interactive Liquid Glass — the disc
/// flexes and lights under the pointer, and siblings in the same
/// `GlassEffectContainer` blend into one another as they press.
@available(macOS 26, *)
private struct GlassTransportButton: View {
    var systemImage: String
    var label: String
    var glyphSize: CGFloat
    var side: CGFloat
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            CadenceIcon(systemImage, size: glyphSize)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.35))
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(isEnabled), in: .circle)
        .accessibilityLabel(label)
        .help(label)
    }
}

