import SwiftUI
import AppKit
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
    @Environment(ArtworkLoader.self) private var loader

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

    /// Longest edge in points. Drives which cached thumbnail is asked for, so
    /// a 32pt queue row never decodes the same image a 540pt immersive view
    /// needs.
    var displaySize: Int = 64
    /// What VoiceOver should call this image, if anything. Cover art inside a
    /// labelled row is decorative; the immersive view's artwork is the subject
    /// of the screen and deserves saying.
    var accessibilityLabel: String?

    var body: some View {
        // Color.clear takes exactly the size it is offered, and the cover is
        // drawn as an overlay on top of it. Putting the image in the layout
        // directly does not work: `.aspectRatio(.fill)` makes it *larger* than
        // the space offered, and it then overflows a frame applied by the
        // caller — a 248pt square cover rendering 328pt wide.
        Color.clear
            .overlay {
                if let image = loader.image(for: artworkID, size: displaySize) {
                    Image(nsImage: image)
                        .resizable()
                        // Covers are square by convention but not by guarantee;
                        // filling crops rather than letterboxing an odd one.
                        .aspectRatio(contentMode: .fill)
                } else {
                    ArtworkPlaceholder(caption: caption, captionSize: captionSize,
                                       stripe: stripe)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.stroke(Tokens.Palette.placeholderBorder, lineWidth: 1)
            }
            .accessibilityHidden(accessibilityLabel == nil)
            .accessibilityLabel(accessibilityLabel ?? "")
            .accessibilityAddTraits(.isImage)
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
            // Read in sentence case: VoiceOver spells out short all-caps words
            // letter by letter.
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The bordered pill carrying a format or sample rate. Accented for the codec,
/// neutral for everything else.
struct QualityBadge: View {
    var text: String
    var emphasis: Emphasis = .neutral

    enum Emphasis { case accent, neutral }

    /// Spoken form, since "24/96" reads as a date and "16/44.1" as nonsense.
    var spokenText: String?

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
            .accessibilityLabel(spokenText ?? text)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cadence")
        .accessibilityValue(isPlaying ? "Playing" : "Not playing")
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
    /// Spoken position, e.g. "1 minute 28 seconds of 5 minutes 38 seconds".
    var accessibilityValue: String?
    var accessibilityLabel: String = "Playback position"
    /// Step for VoiceOver's increment and decrement, as a fraction.
    var step: Double = 0.05
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
        // Without this the scrubber is a bare gesture: invisible to VoiceOver
        // and unreachable from the keyboard.
        //
        // `.accessibilityElement()` plus an adjustable action does expose it,
        // but with role AXUnknown — assistive technology sees something with a
        // name and no idea what it is. Representing it as a real Slider gives
        // it the right role and the interaction users expect, while the drawing
        // above stays exactly as designed.
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { min(max(0, fraction), 1) },
                               set: { onScrub($0) }),
                in: 0...1,
                step: step
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue
                ?? "\(Int((fraction * 100).rounded())) percent")
        }
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

/// One glyph, a hover wash, and a name for VoiceOver. The sidebar's add
/// button and anything else too small to carry a label.
struct IconButton: View {
    var systemImage: String
    /// Required: a glyph alone says nothing aloud, and it doubles as the
    /// tooltip.
    var label: String
    var glyphSize: CGFloat = 11
    var side: CGFloat = 20
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(isHovering
                                 ? Color(hex: 0xEDEDF2) : Color(hex: 0x6E6E78))
                .frame(width: side, height: side)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                     style: .continuous)
                        .fill(isHovering ? Tokens.Palette.navHover : .clear)
                }
        }
        .plainControl()
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// An artist or album name inside a track row, styled like the plain text
/// around it until hovered — brightening and underlining, the way a link
/// does, rather than sitting permanently accent-colored in a dense table. A
/// `Button` rather than a bare `.onTapGesture`: rows that carry it also carry
/// their own double-click-to-play, drag, or `List` selection, and a control
/// keeps its own hit target instead of fighting theirs.
struct InlineLink: View {
    var text: String
    var font: Font
    var color: Color
    var lineLimit: Int? = 1
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(font)
                .foregroundStyle(isHovering ? Tokens.Palette.textPrimary : color)
                .underline(isHovering)
                .lineLimit(lineLimit)
        }
        .plainControl()
        .onHover { isHovering = $0 }
        // Unlike `plainControl()`'s buttons, this reads as a hyperlink —
        // underline and all — so the cursor should say so too (issue #76).
        // `NSCursor.set()` inside `.onHover` looked right but wasn't: AppKit
        // re-resolves the cursor on every `cursorUpdate` as the mouse moves,
        // which stomps a one-shot imperative `.set()` almost immediately, so
        // it never visibly stuck. A real cursor rect via `resetCursorRects`
        // is what AppKit consults on those updates, so it's the only form
        // that survives them.
        .pointingHandCursor()
    }
}

/// A zero-size `NSView` whose only job is a cursor rect covering whatever
/// SwiftUI overlays it on. AppKit only asks a view to declare its cursor
/// rects — via `resetCursorRects` — when it actually needs them (layout,
/// becoming key, entering a new window); once declared, it owns that region
/// until the next ask, so it doesn't get re-fought on every `cursorUpdate`
/// the way an imperative `NSCursor.set()` in `.onHover` does.
private struct CursorRectView: NSViewRepresentable {
    var cursor: NSCursor

    func makeNSView(context: Context) -> NSView { _CursorRectNSView(cursor: cursor) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? _CursorRectNSView)?.cursor = cursor
    }

    private final class _CursorRectNSView: NSView {
        var cursor: NSCursor
        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    }
}

extension View {
    /// Declares a pointing-hand cursor rect over this view's bounds — see
    /// `CursorRectView` for why this, rather than `NSCursor.set()` in
    /// `.onHover`, is the form that actually sticks.
    func pointingHandCursor() -> some View {
        background(CursorRectView(cursor: .pointingHand))
    }
}

extension View {
    /// A named accessibility action that only exists when `isAvailable` is
    /// true — for a row whose link is itself conditional, like a track's
    /// artist link that only appears on a compilation. An action offered on
    /// every row regardless would tell the rotor about a destination the
    /// screen never actually shows.
    @ViewBuilder
    func accessibilityAction(
        named name: String, isAvailable: Bool, _ handler: @escaping () -> Void
    ) -> some View {
        if isAvailable {
            accessibilityAction(named: name, handler)
        } else {
            self
        }
    }
}

/// A screen with nothing on it yet: the ring mark, what is missing, and the
/// one action that fixes it. Shared so an empty library and an empty playlist
/// shelf do not drift into two different apologies.
struct EmptyState<Action: View>: View {
    var systemImage: String
    var title: String
    var message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Tokens.Space.l) {
            ZStack {
                Circle()
                    .strokeBorder(Tokens.Palette.accent.opacity(0.25), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .ultraLight))
                    .foregroundStyle(Tokens.Palette.accent)
            }
            .accessibilityHidden(true)

            VStack(spacing: Tokens.Space.s) {
                Text(title)
                    .font(Tokens.Typography.sans(22, .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Tokens.Palette.textPrimary)

                Text(message)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            action
                .padding(.top, Tokens.Space.xs)
        }
    }
}

/// The accent-filled Play pill and its outlined siblings on the album header.
struct CapsuleButton: View {
    enum Kind { case filled, outlined }

    var title: String?
    var systemImage: String?
    var kind: Kind = .outlined
    /// Held down while a menu this button opened is still on screen. The one
    /// thing the AppKit menu it replaces could never say: which control you
    /// are looking at the menu *of*.
    var isActive: Bool = false
    /// Required when there is no title — an icon alone says nothing aloud.
    var accessibilityLabel: String?
    var action: () -> Void

    @State private var isHovering = false
    /// The button draws itself, so `.disabled` has no effect on how it looks
    /// unless it is read back. An empty playlist's Play pill rendered at full
    /// accent while doing nothing, which reads as a broken button.
    @Environment(\.isEnabled) private var isEnabled

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
            .foregroundStyle(foreground)
            .frame(height: 38)
            .padding(.horizontal, title == nil ? 0 : (kind == .filled ? 20 : 18))
            .frame(width: title == nil ? 38 : nil)
            .background {
                Capsule().fill(fill)
            }
            .overlay {
                if kind == .outlined {
                    Capsule().strokeBorder(border, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .plainControl()
        .onHover { isHovering = $0 }
        // Icon-only buttons have no text to fall back on.
        .accessibilityLabel(accessibilityLabel ?? title ?? "Button")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // The three colours the button can be, kept out of the body so the active
    // case is legible rather than a third clause on every ternary.

    private var foreground: Color {
        if kind == .filled { return .white }
        if isActive { return Tokens.Palette.accent }
        return isHovering && isEnabled ? .white : Color(hex: 0xCACAD3)
    }

    private var fill: Color {
        if kind == .filled {
            return isHovering && isEnabled
                ? Tokens.Palette.accentHover : Tokens.Palette.accent
        }
        return isActive ? Tokens.Palette.accentDim : .clear
    }

    private var border: Color {
        if isActive { return Tokens.Palette.accentEdge }
        return isHovering && isEnabled ? Color(hex: 0x4A4A55) : Color(hex: 0x32323B)
    }
}
