import AppKit

/// Procedural album covers for the showcase library.
///
/// Marketing screenshots need a wall of convincing records, and real covers
/// are someone else's artwork. These are drawn from a style and a seed, so
/// every run produces the same image and nothing is borrowed.
enum ShowcaseCover {

    enum Style {
        /// Bold diagonal bands — rock.
        case bands
        /// Soft overlapping colour blobs — pop.
        case orbs
        /// Big set type over a tinted block, a nod to 1960s jazz sleeves.
        case jazz
        /// Layered hills under a pale sky — folk.
        case hills
        /// A grid of dots scaled by a wave — electronic.
        case dots
        /// Halftone circle and heavy type — hip-hop.
        case halftone
        /// Cream card, thin rule, serif type — classical.
        case classical
        /// Rays from a low sun — soul, funk, Latin.
        case sunburst
        /// Jagged peaks in near-black — metal.
        case peaks
    }

    struct Spec {
        var style: Style
        var colors: [NSColor]
        var seed: UInt64
    }

    static let side = 1_000

    /// PNG bytes for one cover.
    static func png(_ spec: Spec, artist: String, title: String) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        var rng = Seeded(spec.seed)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let c = spec.colors

        switch spec.style {
        case .bands: drawBands(rect, c, &rng, artist: artist, title: title)
        case .orbs: drawOrbs(rect, c, &rng, artist: artist, title: title)
        case .jazz: drawJazz(rect, c, artist: artist, title: title)
        case .hills: drawHills(rect, c, &rng, artist: artist, title: title)
        case .dots: drawDots(rect, c, &rng, artist: artist, title: title)
        case .halftone: drawHalftone(rect, c, artist: artist, title: title)
        case .classical: drawClassical(rect, c, artist: artist, title: title)
        case .sunburst: drawSunburst(rect, c, artist: artist, title: title)
        case .peaks: drawPeaks(rect, c, &rng, artist: artist, title: title)
        }

        drawGrain(rect, &rng)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Styles

    private static func drawBands(_ r: CGRect, _ c: [NSColor], _ rng: inout Seeded,
                                  artist: String, title: String) {
        c[0].setFill(); r.fill()
        let path = NSBezierPath()
        let count = 5
        for i in 0..<count {
            let offset = CGFloat(i) * 260 - 300 + rng.next(-40...40)
            path.removeAllPoints()
            path.move(to: CGPoint(x: offset, y: 0))
            path.line(to: CGPoint(x: offset + 140, y: 0))
            path.line(to: CGPoint(x: offset + 140 + 700, y: 1_000))
            path.line(to: CGPoint(x: offset + 700, y: 1_000))
            path.close()
            c[1 + i % (c.count - 1)].setFill()
            path.fill()
        }
        // A band behind the type, so it reads over any stripe.
        c[0].withAlphaComponent(0.88).setFill()
        CGRect(x: 0, y: 30, width: 1_000, height: 340).fill()
        text(title.uppercased(), font: font("Futura-CondensedExtraBold", 118),
             color: .white, at: CGPoint(x: 60, y: 110), width: 880)
        text(artist.uppercased(), font: font("Futura-Medium", 34), color: .white,
             at: CGPoint(x: 64, y: 60), width: 880, kern: 8)
    }

    private static func drawOrbs(_ r: CGRect, _ c: [NSColor], _ rng: inout Seeded,
                                 artist: String, title: String) {
        c[0].setFill(); r.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for i in 0..<6 {
            let color = c[1 + i % (c.count - 1)]
            let center = CGPoint(x: rng.next(100...900), y: rng.next(250...950))
            let radius = rng.next(220...420)
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [color.withAlphaComponent(0.95).cgColor,
                         color.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 1])!
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [])
        }
        text(title.lowercased(), font: font("AvenirNext-Bold", 96),
             color: .white, at: CGPoint(x: 70, y: 120), width: 860)
        text(artist, font: font("AvenirNext-Medium", 40),
             color: NSColor.white.withAlphaComponent(0.85), at: CGPoint(x: 72, y: 70), width: 860)
    }

    private static func drawJazz(_ r: CGRect, _ c: [NSColor], artist: String, title: String) {
        c[0].setFill(); r.fill()
        c[1].setFill()
        CGRect(x: 0, y: 0, width: 1_000, height: 420).fill()
        c[2].setFill()
        CGRect(x: 640, y: 420, width: 360, height: 580).fill()
        NSColor.black.withAlphaComponent(0.85).setFill()
        CGRect(x: 60, y: 480, width: 40, height: 460).fill()
        CGRect(x: 130, y: 480, width: 14, height: 460).fill()
        text(title, font: font("Futura-Bold", 104), color: .white,
             at: CGPoint(x: 60, y: 180), width: 900, lineHeight: 0.92)
        text(artist.uppercased(), font: font("Futura-Medium", 36), color: c[0],
             at: CGPoint(x: 64, y: 70), width: 900, kern: 6)
    }

    private static func drawHills(_ r: CGRect, _ c: [NSColor], _ rng: inout Seeded,
                                  artist: String, title: String) {
        c[0].setFill(); r.fill()
        c.last!.setFill()
        NSBezierPath(ovalIn: CGRect(x: 620, y: 700, width: 150, height: 150)).fill()
        for layer in 0..<4 {
            let base = 560 - CGFloat(layer) * 130
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.line(to: CGPoint(x: 0, y: base))
            var x: CGFloat = 0
            while x < 1_000 {
                let nx = x + rng.next(140...260)
                path.curve(to: CGPoint(x: nx, y: base + rng.next(-60...90)),
                           controlPoint1: CGPoint(x: x + 60, y: base + rng.next(20...140)),
                           controlPoint2: CGPoint(x: nx - 60, y: base + rng.next(-40...100)))
                x = nx
            }
            path.line(to: CGPoint(x: 1_000, y: 0))
            path.close()
            c[1 + layer % (c.count - 2)].blended(withFraction: CGFloat(layer) * 0.18, of: .black)!.setFill()
            path.fill()
        }
        text(title, font: font("Georgia-Italic", 84), color: NSColor(white: 0.97, alpha: 1),
             at: CGPoint(x: 70, y: 120), width: 860)
        text(artist.uppercased(), font: font("Georgia", 32), color: NSColor(white: 0.9, alpha: 1),
             at: CGPoint(x: 72, y: 70), width: 860, kern: 6)
    }

    private static func drawDots(_ r: CGRect, _ c: [NSColor], _ rng: inout Seeded,
                                 artist: String, title: String) {
        c[0].setFill(); r.fill()
        let phase = rng.next(0...6)
        for row in 0..<16 {
            for col in 0..<16 {
                let x = CGFloat(col) * 60 + 50
                let y = CGFloat(row) * 60 + 50
                let wave = (sin(CGFloat(col) * 0.5 + phase) + cos(CGFloat(row) * 0.4 + phase)) / 2
                let size = 8 + (wave + 1) * 18
                c[1 + (row + col) % (c.count - 1)].withAlphaComponent(0.35 + (wave + 1) * 0.3).setFill()
                NSBezierPath(ovalIn: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)).fill()
            }
        }
        c[0].withAlphaComponent(0.85).setFill()
        CGRect(x: 0, y: 40, width: 1_000, height: 190).fill()
        text(title.uppercased(), font: font("Menlo-Bold", 64), color: .white,
             at: CGPoint(x: 60, y: 130), width: 880, kern: 4)
        text(artist.lowercased(), font: font("Menlo-Regular", 34), color: c[1],
             at: CGPoint(x: 62, y: 75), width: 880)
    }

    private static func drawHalftone(_ r: CGRect, _ c: [NSColor], artist: String, title: String) {
        c[0].setFill(); r.fill()
        let center = CGPoint(x: 620, y: 600)
        for row in 0..<40 {
            for col in 0..<40 {
                let p = CGPoint(x: CGFloat(col) * 26, y: CGFloat(row) * 26)
                let d = hypot(p.x - center.x, p.y - center.y)
                guard d < 420 else { continue }
                let size = (1 - d / 420) * 22 + 2
                c[1].setFill()
                NSBezierPath(ovalIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)).fill()
            }
        }
        text(title.uppercased(), font: font("AvenirNextCondensed-Heavy", 140), color: c[2],
             at: CGPoint(x: 50, y: 150), width: 920, lineHeight: 0.85)
        text(artist.uppercased(), font: font("AvenirNextCondensed-DemiBold", 44), color: .white,
             at: CGPoint(x: 54, y: 70), width: 920, kern: 4)
    }

    private static func drawClassical(_ r: CGRect, _ c: [NSColor], artist: String, title: String) {
        c[0].setFill(); r.fill()
        c[1].setStroke()
        let border = NSBezierPath(rect: r.insetBy(dx: 60, dy: 60))
        border.lineWidth = 3
        border.stroke()
        c[2].setFill()
        NSBezierPath(ovalIn: CGRect(x: 380, y: 560, width: 240, height: 240)).fill()
        c[0].setFill()
        NSBezierPath(ovalIn: CGRect(x: 430, y: 610, width: 140, height: 140)).fill()
        let parts = title.components(separatedBy: ": ")
        text(parts[0].uppercased(), font: font("Didot-Bold", 52), color: c[1],
             at: CGPoint(x: 110, y: 380), width: 780, align: .center, kern: 10)
        if parts.count > 1 {
            text(parts[1], font: font("Didot-Italic", 76), color: c[1],
                 at: CGPoint(x: 110, y: 270), width: 780, align: .center)
        }
        text(artist, font: font("Didot", 34), color: c[1].withAlphaComponent(0.8),
             at: CGPoint(x: 110, y: 140), width: 780, align: .center)
    }

    private static func drawSunburst(_ r: CGRect, _ c: [NSColor], artist: String, title: String) {
        c[0].setFill(); r.fill()
        let origin = CGPoint(x: 500, y: 330)
        for i in 0..<18 where i.isMultiple(of: 2) {
            let a0 = CGFloat(i) * .pi / 18
            let a1 = CGFloat(i + 1) * .pi / 18
            let path = NSBezierPath()
            path.move(to: origin)
            path.line(to: CGPoint(x: origin.x + cos(a0) * 1_400, y: origin.y + sin(a0) * 1_400))
            path.line(to: CGPoint(x: origin.x + cos(a1) * 1_400, y: origin.y + sin(a1) * 1_400))
            path.close()
            c[1].setFill()
            path.fill()
        }
        c[2].setFill()
        NSBezierPath(ovalIn: CGRect(x: 330, y: 160, width: 340, height: 340)).fill()
        c[3].setFill()
        CGRect(x: 0, y: 0, width: 1_000, height: 330).fill()
        text(title, font: font("Cochin-BoldItalic", 96), color: c[2],
             at: CGPoint(x: 60, y: 150), width: 880, align: .center)
        text(artist.uppercased(), font: font("AvenirNext-DemiBold", 34),
             color: NSColor.white.withAlphaComponent(0.85),
             at: CGPoint(x: 60, y: 80), width: 880, align: .center, kern: 8)
    }

    private static func drawPeaks(_ r: CGRect, _ c: [NSColor], _ rng: inout Seeded,
                                  artist: String, title: String) {
        c[0].setFill(); r.fill()
        for layer in 0..<3 {
            let path = NSBezierPath()
            let base = 300 + CGFloat(layer) * 60
            path.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            path.line(to: CGPoint(x: 0, y: base))
            while x < 1_000 {
                x += rng.next(60...140)
                path.line(to: CGPoint(x: x, y: base + rng.next(80...420 - CGFloat(layer) * 90)))
                x += rng.next(40...100)
                path.line(to: CGPoint(x: x, y: base - rng.next(0...60)))
            }
            path.line(to: CGPoint(x: 1_000, y: 0))
            path.close()
            c[1 + layer % (c.count - 1)].setFill()
            path.fill()
        }
        text(title.uppercased(), font: font("Copperplate-Bold", 96), color: c.last!,
             at: CGPoint(x: 60, y: 820), width: 880, align: .center, kern: 6)
        text(artist.uppercased(), font: font("Copperplate", 40), color: NSColor(white: 0.85, alpha: 1),
             at: CGPoint(x: 60, y: 760), width: 880, align: .center, kern: 10)
    }

    /// A little noise, so flat fills read as printed rather than rendered.
    private static func drawGrain(_ r: CGRect, _ rng: inout Seeded) {
        for _ in 0..<9_000 {
            let white = rng.next(0...1) > 0.5
            NSColor(white: white ? 1 : 0, alpha: 0.05).setFill()
            CGRect(x: rng.next(0...1_000), y: rng.next(0...1_000), width: 2, height: 2).fill()
        }
    }

    // MARK: - Helpers

    private static func font(_ name: String, _ size: CGFloat) -> NSFont {
        NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .bold)
    }

    private static func text(_ string: String, font: NSFont, color: NSColor, at origin: CGPoint,
                             width: CGFloat, align: NSTextAlignment = .left,
                             kern: CGFloat = 0, lineHeight: CGFloat = 1) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineHeightMultiple = lineHeight
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: style,
        ])
        // Grow upward from the baseline area, so multi-line titles stack above
        // the artist line rather than running into it.
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        attributed.draw(with: CGRect(x: origin.x, y: origin.y, width: width, height: ceil(bounds.height)),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

/// SplitMix64 — deterministic, so a cover is the same on every run.
struct Seeded {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(_ range: ClosedRange<CGFloat>) -> CGFloat {
        let unit = CGFloat(nextRaw() >> 11) / CGFloat(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
