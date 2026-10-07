import SwiftUI
import AppKit

// The Cadence icon set.
//
// Every glyph is drawn on a 24-unit grid with a 1.75 stroke and round caps
// and joins. Filled shapes (transport, volume) carry the app's voice; the
// rest are lined. The artwork lives here as SVG path data so it can be
// compared one-to-one with the design sheet.
//
// Call sites pass the SF Symbol name the glyph replaced, as a stable key, and
// `CadenceIcon` looks it up in `CadenceGlyph.table`. No system symbols are
// drawn anywhere in the app.

/// How a glyph is sized: `size` is the point size an `Image(systemName:)`
/// would have had at the same call site. The artwork keeps a 2-unit margin
/// inside its 24-unit box, so the box is `boxScale` larger than `size` to
/// make the visible glyph match; `boxScale` trims that for dense rows.
struct CadenceIcon: View {
    static let boxScale: CGFloat = 1.4

    let name: String
    var size: CGFloat = 13
    var boxScale: CGFloat = CadenceIcon.boxScale

    init(_ name: String, size: CGFloat = 13, boxScale: CGFloat = CadenceIcon.boxScale) {
        self.name = name
        self.size = size
        self.boxScale = boxScale
    }

    var body: some View {
        if let glyph = CadenceGlyph.table[name] {
            let side = size * boxScale
            Canvas { context, canvas in
                let scale = min(canvas.width, canvas.height) / CadenceGlyph.artboard
                context.scaleBy(x: scale, y: scale)
                for part in glyph.parts {
                    if part.fill {
                        context.fill(part.path, with: .foreground)
                    }
                    if let width = part.stroke {
                        context.stroke(part.path, with: .foreground,
                                       style: StrokeStyle(lineWidth: width,
                                                          lineCap: .round,
                                                          lineJoin: .round))
                    }
                }
            }
            .frame(width: side, height: side)
            .accessibilityHidden(true)
        } else {
            // Every name the app passes has art; a miss is a missing table
            // entry, not something to paper over with a system symbol.
            let _ = assertionFailure("No Cadence glyph named \(name)")
            Color.clear.frame(width: size * boxScale, height: size * boxScale)
        }
    }
}

struct CadenceGlyph: Sendable {
    static let artboard: CGFloat = 24
    static let strokeWidth: CGFloat = 1.75

    struct Part: Sendable {
        var path: Path
        var fill: Bool
        var stroke: CGFloat?

        /// Stroked outline, the default.
        static func line(_ d: String, width: CGFloat = CadenceGlyph.strokeWidth) -> Part {
            Part(path: SVGPath.parse(d), fill: false, stroke: width)
        }

        /// Filled shape whose stroke rounds its corners.
        static func solid(_ d: String, rounding: CGFloat) -> Part {
            Part(path: SVGPath.parse(d), fill: true, stroke: rounding)
        }

        /// Filled shape with no stroke.
        static func flat(_ d: String) -> Part {
            Part(path: SVGPath.parse(d), fill: true, stroke: nil)
        }

        static func ring(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
                         width: CGFloat = CadenceGlyph.strokeWidth) -> Part {
            Part(path: Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                 fill: false, stroke: width)
        }

        static func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Part {
            Part(path: Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                 fill: true, stroke: nil)
        }

        /// Filled disc whose stroke adds to its radius.
        static func disc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
                         width: CGFloat = CadenceGlyph.strokeWidth) -> Part {
            Part(path: Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                 fill: true, stroke: width)
        }

        static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                         radius: CGFloat, filled: Bool) -> Part {
            Part(path: Path(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                            cornerRadius: radius),
                 fill: filled, stroke: filled ? nil : CadenceGlyph.strokeWidth)
        }
    }

    let parts: [Part]

    /// A template image for places SwiftUI views cannot go, such as the menu
    /// bar item, which the system tints to match the bar.
    @MainActor
    static func templateImage(_ name: String, side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let glyph = table[name], let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            let scale = side / artboard
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for part in glyph.parts {
                if part.fill {
                    context.addPath(part.path.cgPath)
                    context.fillPath()
                }
                if let width = part.stroke {
                    context.addPath(part.path.cgPath)
                    context.setLineWidth(width)
                    context.strokePath()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private init(_ parts: [Part]) { self.parts = parts }

    // MARK: Artwork

    private static let play = CadenceGlyph([.solid("M8.2 5.8v12.4l10.4-6.2z", rounding: 2.4)])
    private static let pause = CadenceGlyph([
        .rect(6.2, 5, 3.8, 14, radius: 1.4, filled: true),
        .rect(14, 5, 3.8, 14, radius: 1.4, filled: true),
    ])
    private static let previous = CadenceGlyph([
        .rect(5, 5, 2.8, 14, radius: 1.2, filled: true),
        .solid("M18.6 6.4v11.2L10 12z", rounding: 2.2),
    ])
    private static let next = CadenceGlyph([
        .rect(16.2, 5, 2.8, 14, radius: 1.2, filled: true),
        .solid("M5.4 6.4v11.2L14 12z", rounding: 2.2),
    ])
    private static let shuffle = CadenceGlyph([.line(
        "M4 17h2.5c4 0 5-10 9-10H20M17.5 4.5 20 7l-2.5 2.5M4 7h2.5c1.6 0 2.7.9 3.6 2.2M13.9 14.8c.9 1.3 2 2.2 3.6 2.2H20M17.5 14.5 20 17l-2.5 2.5")])
    private static let repeatAll = CadenceGlyph([.line(
        "M17 3.5l3 3-3 3M4 12v-2a3.5 3.5 0 0 1 3.5-3.5H20M7 14.5l-3 3 3 3M20 12v2a3.5 3.5 0 0 1-3.5 3.5H4")])
    private static let repeatOne = CadenceGlyph([.line(
        "M17 3.5l3 3-3 3M4 12v-2a3.5 3.5 0 0 1 3.5-3.5H20M7 14.5l-3 3 3 3M20 12v2a3.5 3.5 0 0 1-3.5 3.5H4M10.8 10.4 12.6 9.2v5.6")])

    private static let speaker = Part.solid("M3.5 9.5h3l4.5-3.8v12.6l-4.5-3.8h-3z", rounding: 1.5)
    private static let volumeMuted = CadenceGlyph([speaker, .line("M15.5 9.5l5 5M20.5 9.5l-5 5")])
    private static let volumeOff = CadenceGlyph([.solid("M5.5 9.5h3l4.5-3.8v12.6l-4.5-3.8h-3z", rounding: 1.5)])
    private static let volumeLow = CadenceGlyph([speaker, .line("M15 9.4a3.9 3.9 0 0 1 0 5.2")])
    private static let volumeHigh = CadenceGlyph([speaker, .line("M15 9.4a3.9 3.9 0 0 1 0 5.2M17.8 6.6a7.8 7.8 0 0 1 0 10.8")])

    private static let recents = CadenceGlyph([.ring(12, 12, 8.5), .line("M12 7.4V12l3.1 1.9")])
    private static let artists = CadenceGlyph([
        .ring(9.5, 8.5, 3.1),
        .line("M3.5 19c.6-3 3-4.8 6-4.8s5.4 1.8 6 4.8M15.5 5.6a3.1 3.1 0 0 1 0 5.8M17.8 14.6c1.6.7 2.6 2.1 3 4.4"),
    ])
    private static let albums = CadenceGlyph([
        .ring(12, 12, 8.5), .disc(12, 12, 1.2), .line("M12 6.8a5.2 5.2 0 0 1 5.2 5.2"),
    ])
    private static let playlists = CadenceGlyph([
        .line("M4 7h11M4 12h7M4 17h5M18.7 17V8.4l2.3.9"), .ring(16.5, 17.2, 2.2),
    ])
    private static let addToPlaylist = CadenceGlyph([
        .line("M4 6h11M4 11h7M18.7 15V7.4l2.3.9M6.5 14.5v6M3.5 17.5h6"), .ring(16.5, 15.2, 2.2),
    ])
    private static let search = CadenceGlyph([.ring(10.8, 10.8, 6.5), .line("M15.6 15.6l4.6 4.6")])
    private static let preferences = CadenceGlyph([
        .line("M6 4v2.8M6 11.2V20M12 4v8.6M12 17.2V20M18 4v1.6M18 10.4V20"),
        .ring(6, 9, 2.2), .ring(12, 15, 2.2), .ring(18, 8, 2.2),
    ])
    /// A sort arrow beside three tiles that grow toward the top: the menu
    /// holds ordering and zoom.
    private static let viewOptions = CadenceGlyph([
        .line("M6 5v14M4 7l2-2 2 2M4 17l2 2 2-2"),
        .rect(12.5, 4, 5.5, 5.5, radius: 1.3, filled: true),
        .rect(12.5, 11.5, 4, 4, radius: 1, filled: true),
        .rect(12.5, 17.5, 2.5, 2.5, radius: 0.8, filled: true),
    ])
    private static let back = CadenceGlyph([.line("M14.5 6l-6 6 6 6")])
    private static let forward = CadenceGlyph([.line("M9.5 6l6 6-6 6")])
    private static let expand = CadenceGlyph([.line("M14 4h6v6M10 20H4v-6M20 4l-6.5 6.5M4 20l6.5-6.5")])
    private static let grid = CadenceGlyph([
        .rect(4, 4, 6.5, 6.5, radius: 1.8, filled: false),
        .rect(13.5, 4, 6.5, 6.5, radius: 1.8, filled: false),
        .rect(4, 13.5, 6.5, 6.5, radius: 1.8, filled: false),
        .rect(13.5, 13.5, 6.5, 6.5, radius: 1.8, filled: false),
    ])
    private static let list = CadenceGlyph([.line("M4 6.5h16M4 12h16M4 17.5h16")])
    private static let track = CadenceGlyph([
        .line("M9.5 17V6.2l10-2V15"), .ring(7, 17.2, 2.5), .ring(17, 15.2, 2.5),
    ])
    private static let headphones = CadenceGlyph([
        .line("M4.5 15v-3a7.5 7.5 0 0 1 15 0v3"),
        .rect(3.5, 13.8, 4, 6.2, radius: 1.7, filled: false),
        .rect(16.5, 13.8, 4, 6.2, radius: 1.7, filled: false),
    ])
    private static let plus = CadenceGlyph([.line("M12 5v14M5 12h14")])
    private static let remove = CadenceGlyph([.ring(12, 12, 8.5), .line("M8.2 12h7.6")])
    private static let rename = CadenceGlyph([.line(
        "M4.5 19.5l.8-3.9L16.6 4.3a1.8 1.8 0 0 1 2.5 0l.6.6a1.8 1.8 0 0 1 0 2.5L8.4 18.7zM14.5 6.4l3.1 3.1")])
    private static let trash = CadenceGlyph([.line(
        "M4.5 7h15M9.5 7V5a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v2M6.5 7l.8 11.2a1.8 1.8 0 0 0 1.8 1.6h5.8a1.8 1.8 0 0 0 1.8-1.6L17.5 7M10 11v5M14 11v5")])
    private static let addToQueue = CadenceGlyph([.line("M4 7h12M4 12h8M4 17h6M17.5 14v6M14.5 17h6")])
    private static let waveform = CadenceGlyph([.line("M5 10v4M8.5 7v10M12 4.5v15M15.5 8v8M19 10.5v3")])
    private static let folder = CadenceGlyph([.line(
        "M3.5 17V7a2 2 0 0 1 2-2h3.4l2 2.2h7.6a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z")])
    private static let info = CadenceGlyph([.ring(12, 12, 8.5), .line("M12 11v5.4"), .disc(12, 7.9, 0.6, width: 0.9)])
    private static let credits = CadenceGlyph([
        .rect(4, 4, 16, 16, radius: 3.5, filled: false), .ring(9.5, 10, 1.9),
        .line("M6.6 16.4c.4-1.6 1.5-2.4 2.9-2.4s2.5.8 2.9 2.4M14.8 9.4h2.2M14.8 13h2.2"),
    ])
    private static let refresh = CadenceGlyph([.line("M19.5 12a7.5 7.5 0 1 1-2.3-5.4M19.5 4.5v4h-4")])
    private static let close = CadenceGlyph([.line("M6 6l12 12M18 6L6 18")])
    private static let handle = CadenceGlyph([
        .dot(9, 7, 1.3), .dot(15, 7, 1.3), .dot(9, 12, 1.3),
        .dot(15, 12, 1.3), .dot(9, 17, 1.3), .dot(15, 17, 1.3),
    ])
    private static let undo = CadenceGlyph([.line("M9 6 4.5 10.5 9 15M5 10.5h8a4.5 4.5 0 0 1 0 9H10")])
    private static let check = CadenceGlyph([.line("M5 12.5l4.5 4.5L19 7.5")])
    private static let arrow = CadenceGlyph([.line("M5 12h14M13 6l6 6-6 6")])
    private static let stack = CadenceGlyph([
        .rect(4, 9, 16, 11, radius: 2.5, filled: false), .line("M7 6h10M9.5 3h5"),
    ])
    private static let more = CadenceGlyph([.dot(5.5, 12, 1.5), .dot(12, 12, 1.5), .dot(18.5, 12, 1.5)])
    private static let warning = CadenceGlyph([
        .line("M12 4.2L21 19.5H3z"), .line("M12 10v4.4"), .disc(12, 17, 0.6, width: 0.9),
    ])
    private static let added = CadenceGlyph([.ring(12, 12, 8.5), .line("M8.3 12.3l2.7 2.7 4.8-5.3")])
    private static let clear = CadenceGlyph([.ring(12, 12, 8.5), .line("M9 9l6 6M15 9l-6 6")])
    private static let edit = CadenceGlyph([
        .ring(12, 12, 8.5),
        .line("M8.2 15.8l.5-2.4 5.3-5.3a1.2 1.2 0 0 1 1.7 0l.2.2a1.2 1.2 0 0 1 0 1.7l-5.3 5.3z"),
    ])

    /// Keyed by the SF Symbol each glyph replaces, plus two names with no SF
    /// equivalent that the app reuses for a verb: `text.badge.plus` (add to
    /// playlist) and `music.note.list` (the playlist itself).
    static let table: [String: CadenceGlyph] = [
        "play.fill": play,
        "pause.fill": pause,
        "backward.fill": previous,
        "forward.fill": next,
        "shuffle": shuffle,
        "repeat": repeatAll,
        "repeat.1": repeatOne,
        "speaker.slash.fill": volumeMuted,
        "speaker.fill": volumeOff,
        "speaker.wave.1.fill": volumeLow,
        "speaker.wave.2.fill": volumeHigh,
        "clock": recents,
        "person": artists,
        "circle.circle": albums,
        "music.note.list": playlists,
        "text.badge.plus": addToPlaylist,
        "magnifyingglass": search,
        "gearshape": preferences,
        "slider.horizontal.3": viewOptions,
        "chevron.left": back,
        "chevron.right": forward,
        "arrow.up.left.and.arrow.down.right": expand,
        "square.grid.2x2": grid,
        "list.bullet": list,
        "music.note": track,
        "headphones": headphones,
        "plus": plus,
        "minus.circle": remove,
        "pencil": rename,
        "trash": trash,
        "text.append": addToQueue,
        "waveform": waveform,
        "folder": folder,
        "info.circle": info,
        "person.2": credits,
        "arrow.clockwise": refresh,
        "xmark": close,
        "line.3.horizontal": handle,
        "arrow.uturn.backward": undo,
        "checkmark": check,
        "arrow.right": arrow,
        "square.stack": stack,
        "ellipsis": more,
        "exclamationmark.triangle": warning,
        "exclamationmark.triangle.fill": warning,
        "checkmark.circle.fill": added,
        "xmark.circle.fill": clear,
        "pencil.circle.fill": edit,
    ]
}

// MARK: - SVG path data

/// Parses the subset of SVG path syntax the icon artwork uses: M L H V C S A Z
/// in absolute and relative forms. Arcs must be unrotated, which is all the
/// artwork needs.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var scanner = PathScanner(d)
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = "M"

        while scanner.skipSeparators() {
            if let next = scanner.command() {
                command = next
                if command == "Z" || command == "z" {
                    path.closeSubpath()
                    current = start
                    lastControl = nil
                    continue
                }
            }
            let relative = command.isLowercase
            let origin = relative ? current : .zero

            switch command.uppercased() {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                start = current
                path.move(to: current)
                // Further pairs after a moveto are implicit linetos.
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                path.addLine(to: current)
                lastControl = nil
            case "H":
                guard let x = scanner.number() else { return path }
                current.x = origin.x + x
                path.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = scanner.number() else { return path }
                current.y = origin.y + y
                path.addLine(to: current)
                lastControl = nil
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = CGPoint(x: origin.x + x1, y: origin.y + y1)
                let c2 = CGPoint(x: origin.x + x2, y: origin.y + y2)
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = CGPoint(x: origin.x + x2, y: origin.y + y2)
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      scanner.number() != nil,
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = CGPoint(x: origin.x + x, y: origin.y + y)
                addArc(to: &path, from: current, to: end, rx: rx, ry: ry, large: large, sweep: sweep)
                current = end
                lastControl = nil
            default:
                return path
            }
        }
        return path
    }

    /// Endpoint arc to cubic segments (SVG implementation notes F.6.5).
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, large: Bool, sweep: Bool) {
        guard p0 != p1, rxIn != 0, ryIn != 0 else {
            path.addLine(to: p1)
            return
        }
        var rx = abs(rxIn), ry = abs(ryIn)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let lambda = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * dy * dy - ry * ry * dx * dx
        let denominator = rx * rx * dy * dy + ry * ry * dx * dx
        let sign: CGFloat = large == sweep ? -1 : 1
        let coefficient = sign * max(0, numerator / denominator).squareRoot()
        let cxp = coefficient * rx * dy / ry
        let cyp = -coefficient * ry * dx / rx
        let cx = cxp + (p0.x + p1.x) / 2
        let cy = cyp + (p0.y + p1.y) / 2

        let theta1 = atan2((dy - cyp) / ry, (dx - cxp) / rx)
        let theta2 = atan2((-dy - cyp) / ry, (-dx - cxp) / rx)
        var delta = theta2 - theta1
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var angle = theta1
        for _ in 0..<segments {
            let next = angle + step
            let c1 = CGPoint(x: cx + rx * (cos(angle) - k * sin(angle)),
                             y: cy + ry * (sin(angle) + k * cos(angle)))
            let c2 = CGPoint(x: cx + rx * (cos(next) + k * sin(next)),
                             y: cy + ry * (sin(next) - k * cos(next)))
            let end = CGPoint(x: cx + rx * cos(next), y: cy + ry * sin(next))
            path.addCurve(to: end, control1: c1, control2: c2)
            angle = next
        }
    }

    private struct PathScanner {
        private let chars: [Character]
        private var index = 0

        init(_ string: String) { chars = Array(string) }

        /// Skips whitespace and commas; false at the end of the string.
        mutating func skipSeparators() -> Bool {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" {
                index += 1
            }
            return index < chars.count
        }

        mutating func command() -> Character? {
            guard index < chars.count, chars[index].isLetter else { return nil }
            defer { index += 1 }
            return chars[index]
        }

        /// A single 0 or 1, which SVG lets run into the next number.
        mutating func flag() -> Bool? {
            _ = skipSeparators()
            guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
            defer { index += 1 }
            return chars[index] == "1"
        }

        mutating func number() -> CGFloat? {
            _ = skipSeparators()
            let begin = index
            if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
            var sawDot = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    index += 1
                } else if c == ".", !sawDot {
                    sawDot = true
                    index += 1
                } else {
                    break
                }
            }
            guard index > begin, let value = Double(String(chars[begin..<index])) else { return nil }
            return CGFloat(value)
        }
    }
}
