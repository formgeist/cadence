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

    var body: some View {
        if let track = playback.currentTrack {
            Label {
                Text("\(track.title) · \(track.artist)")
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
struct MenuBarPlaybackView: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        VStack(spacing: Tokens.Space.m) {
            if let track = playback.currentTrack {
                ArtworkView(artworkID: track.artworkID,
                            cornerRadius: Tokens.Radius.card,
                            displaySize: 176)
                    .frame(width: 176, height: 176)

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
                ArtworkPlaceholder()
                    .frame(width: 176, height: 176)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))

                Text("Not Playing")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }

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
        .padding(Tokens.Space.l)
        .frame(width: 208)
        .background(Tokens.Palette.popover)
    }
}
