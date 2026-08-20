import SwiftUI
import CadenceCore

// MARK: - Artwork

/// The diagonal hatch the design uses wherever a cover would go. It is not a
/// grey box: real libraries have plenty of albums with no artwork, and this is
/// what those look like in Cadence rather than an apologetic placeholder.
struct ArtworkPlaceholder: View {
    var caption: String?
    var captionSize: CGFloat = 9.5
    var stripe: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Tokens.Palette.placeholderDark))
            // 45° bands, `stripe` wide with `stripe` between them, matching
            // the mock's repeating-linear-gradient.
            let span = size.width + size.height
            var offset: CGFloat = -size.height
            var path = Path()
            while offset < span {
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                offset += stripe * 2
            }
            context.stroke(path, with: .color(Tokens.Palette.placeholderLight),
                           lineWidth: stripe)
        }
        .overlay(alignment: .bottomLeading) {
            if let caption {
                Text(caption)
                    .font(Tokens.Typography.mono(captionSize))
                    .tracking(0.6)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .padding(captionSize > 9.5 ? Tokens.Space.m : Tokens.Space.s + 2)
                    .lineSpacing(3)
            }
        }
        .clipped()
    }
}

/// Cover art at any size. Falls back to the hatch, which is the common case
/// until the artwork store exists.
struct ArtworkView: View {
    var artworkID: Artwork.ID?
    var cornerRadius: CGFloat = Tokens.Radius.thumb
    /// Artists are round in the design. A continuous RoundedRectangle at half
    /// the side length is a squircle, not a circle — it reads as an octagon at
    /// avatar sizes — so round artwork gets an actual Circle.
    var isCircular: Bool = false
    var caption: String?
    var captionSize: CGFloat = 9.5
    var stripe: CGFloat = 5

    private var shape: AnyShape {
        isCircular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    var body: some View {
        ArtworkPlaceholder(caption: caption, captionSize: captionSize, stripe: stripe)
            .clipShape(shape)
            .overlay {
                shape.stroke(Tokens.Palette.placeholderBorder, lineWidth: 1)
            }
    }
}

// MARK: - Labels

/// The mono, wide-tracked, all-caps label the design uses for every section
/// heading: LIBRARY, UP NEXT, NOW PLAYING, TITLE.
struct SectionLabel: View {
    var text: String
    var size: CGFloat = 10
    var color: Color = Tokens.Palette.textMuted

    init(_ text: String, size: CGFloat = 10, color: Color = Tokens.Palette.textMuted) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Tokens.Typography.mono(size, .medium))
            .tracking(Tokens.Typography.Tracking.label)
            .foregroundStyle(color)
    }
}

/// The bordered pill carrying a format or sample rate. Accented for the codec,
/// neutral for everything else.
struct QualityBadge: View {
    var text: String
    var emphasis: Emphasis = .neutral

    enum Emphasis { case accent, neutral }

    var body: some View {
        Text(text)
            .font(Tokens.Typography.mono(10, .medium))
            .tracking(Tokens.Typography.Tracking.badge)
            .foregroundStyle(emphasis == .accent
                             ? Tokens.Palette.accent : Color(hex: 0x8D8D98))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.thumb, style: .continuous)
                    .fill(emphasis == .accent ? Tokens.Palette.accentDim : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.thumb, style: .continuous)
                    .strokeBorder(emphasis == .accent
                                  ? Tokens.Palette.accentEdge : Tokens.Palette.borderStrong,
                                  lineWidth: 1)
            }
    }
}

// MARK: - Wordmark

/// The spinning ring mark. It turns only while audio is playing, which makes it
/// the quietest playback indicator in the app.
struct Wordmark: View {
    var isPlaying: Bool
    @State private var angle: Double = 0

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .strokeBorder(Tokens.Palette.accent, lineWidth: 1.5)
                Circle()
                    .strokeBorder(Tokens.Palette.accent.opacity(0.45), lineWidth: 1)
                    .padding(3)
                // The index mark, so the rotation is visible at all.
                Capsule()
                    .fill(Tokens.Palette.accent.opacity(0.85))
                    .frame(width: 1.5, height: 4)
                    .offset(y: -6.5)
                Circle()
                    .fill(Tokens.Palette.accent)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 18, height: 18)
            .background {
                Circle().fill(Tokens.Palette.accent.opacity(0.12)).padding(-3)
            }
            .rotationEffect(.degrees(angle))
            .animation(isPlaying
                       ? .linear(duration: 3).repeatForever(autoreverses: false)
                       : .default,
                       value: angle)
            .onAppear { if isPlaying { angle = 360 } }
            .onChange(of: isPlaying) { _, playing in
                // Restarting from the current angle rather than zero avoids a
                // visible snap when playback resumes.
                angle = playing ? angle + 360 : angle.truncatingRemainder(dividingBy: 360)
            }

            Text("CADENCE")
                .font(Tokens.Typography.sans(13, .heavy))
                .tracking(Tokens.Typography.Tracking.wordmark)
                .foregroundStyle(Color(hex: 0xEDEDF2))
        }
    }
}

// MARK: - Rows

/// Row highlight on hover, used by every list in the app. Kept as a modifier so
/// the hover colour lives in exactly one place.
struct HoverHighlight: ViewModifier {
    var isActive: Bool = false
    var radius: CGFloat = Tokens.Radius.control
    var hoverColor: Color = Tokens.Palette.rowHover
    var activeColor: Color = Tokens.Palette.rowActive
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isActive ? activeColor : (isHovering ? hoverColor : .clear))
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverHighlight(
        isActive: Bool = false,
        radius: CGFloat = Tokens.Radius.control,
        hoverColor: Color = Tokens.Palette.rowHover,
        activeColor: Color = Tokens.Palette.rowActive
    ) -> some View {
        modifier(HoverHighlight(isActive: isActive, radius: radius,
                                hoverColor: hoverColor, activeColor: activeColor))
    }
}

// MARK: - Progress

/// The transport scrubber. A bare capsule at rest, exactly as drawn; the knob
/// and the enlarged hit area only exist on hover, so the resting state stays as
/// quiet as the mock.
struct ScrubBar: View {
    var fraction: Double
    var height: CGFloat = 3
    var onScrub: (Double) -> Void

    @State private var isHovering = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Palette.trackGroove)
                Capsule()
                    .fill(Tokens.Palette.accent)
                    .frame(width: max(0, min(1, fraction)) * width)
                if isHovering {
                    Circle()
                        .fill(Tokens.Palette.accent)
                        .frame(width: height * 3, height: height * 3)
                        .offset(x: max(0, min(1, fraction)) * width - height * 1.5)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onScrub(min(max(0, $0.location.x / width), 1)) }
            )
        }
        // A 3px-tall bar is an unusable drag target; the row is taller than the
        // bar it draws.
        .frame(height: max(height, 12))
    }
}

// MARK: - Buttons

/// Bare button styling — no bezel, no focus ring, just the content. Every
/// control in the design is a styled div, so this is the baseline.
struct PlainControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Pointer stays an arrow over controls, the way it does in a native Mac
    /// app rather than a web page.
    func plainControl() -> some View { buttonStyle(PlainControlStyle()) }
}

/// The accent-filled Play pill and its outlined siblings on the album header.
struct CapsuleButton: View {
    enum Kind { case filled, outlined }

    var title: String?
    var systemImage: String?
    var kind: Kind = .outlined
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: kind == .filled ? 12 : 13, weight: .bold))
                }
                if let title {
                    Text(title)
                        .font(Tokens.Typography.sans(kind == .filled ? 13.5 : 13,
                                                     kind == .filled ? .bold : .semibold))
                }
            }
            .foregroundStyle(kind == .filled
                             ? .white
                             : (isHovering ? .white : Color(hex: 0xCACAD3)))
            .frame(height: 38)
            .padding(.horizontal, title == nil ? 0 : (kind == .filled ? 20 : 18))
            .frame(width: title == nil ? 38 : nil)
            .background {
                Capsule().fill(kind == .filled
                               ? (isHovering ? Tokens.Palette.accentHover : Tokens.Palette.accent)
                               : .clear)
            }
            .overlay {
                if kind == .outlined {
                    Capsule().strokeBorder(
                        isHovering ? Color(hex: 0x4A4A55) : Color(hex: 0x32323B),
                        lineWidth: 1)
                }
            }
        }
        .plainControl()
        .onHover { isHovering = $0 }
    }
}
