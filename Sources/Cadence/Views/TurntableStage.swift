import SwiftUI
import CadenceCore

/// The immersive view's centrepiece: the current cover propped on a small
/// wall shelf, with the record itself spinning on a turntable underneath.
///
/// Everything is drawn in a fixed design canvas (`Canvas.size`) and scaled as
/// one piece to fit whatever room the stage has, so the shelf, sleeve and deck
/// keep their proportions from the smallest window to a full-screen display.
struct TurntableStage: View {
    var artworkID: Artwork.ID?
    var isPlaying: Bool
    /// 0…1 through the current track; walks the stylus from the lead-in
    /// groove towards the label the way a real side plays down.
    var progress: Double
    var accessibilityLabel: String?

    enum Canvas {
        static let size = CGSize(width: 660, height: 710)
        static let sleeve: CGFloat = 392
        static let shelfWidth: CGFloat = 520
        static let deckWidth: CGFloat = 600
        /// The deck's top face, drawn flat and then tipped away from the
        /// viewer. Square-ish in plan like a real plinth.
        static let deckDepth: CGFloat = 410
        static let deckTilt: Double = 66
        static let deckFront: CGFloat = 30
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / Canvas.size.width,
                geometry.size.height / Canvas.size.height,
                1.25)

            canvas
                .frame(width: Canvas.size.width, height: Canvas.size.height)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var canvas: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            sleeve
            WallShelf(width: Canvas.shelfWidth)
            Spacer(minLength: 0)
                .frame(height: 52)
            Turntable(
                artworkID: artworkID,
                isPlaying: isPlaying,
                progress: progress)
        }
        .background { keyLight }
    }

    /// One warm overhead light, centred above the shelf and falling off down
    /// the wall, so the sleeve and deck sit in a pool of light rather than
    /// floating on a flat background.
    private var keyLight: some View {
        EllipticalGradient(
            stops: [
                .init(color: Color(hex: 0xFFE9D0).opacity(0.11), location: 0),
                .init(color: Color(hex: 0xFFE9D0).opacity(0.04), location: 0.5),
                .init(color: .clear, location: 1),
            ],
            // Centred, and clear by the inscribed ellipse's edge, so the
            // frame never shows as a hard rectangle.
            center: .center,
            startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: Canvas.size.width * 1.6, height: Canvas.size.height * 1.4)
            .offset(y: -Canvas.size.height * 0.2)
            .blendMode(.screen)
            .allowsHitTesting(false)
    }

    /// The cover stands on the shelf, so its only shadows are a tight contact
    /// line where it meets the wood and a soft cast onto the wall behind.
    private var sleeve: some View {
        ArtworkView(
            artworkID: artworkID,
            cornerRadius: 2.5,
            caption: "ALBUM ARTWORK\n1400 × 1400",
            captionSize: 11,
            stripe: 10,
            displaySize: 600,
            accessibilityLabel: accessibilityLabel
        )
        .frame(width: Canvas.sleeve, height: Canvas.sleeve)
        .overlay { SleeveFinish() }
        // A tight contact line, then the cast onto the wall from a light at
        // the upper left. Real shadows rather than a blurred backing shape,
        // which `ImageRenderer` draws hard-edged.
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.6), radius: 24, x: 14, y: -2)
    }
}

// MARK: - Sleeve

/// Card stock rather than a screen: a faint sheen from the upper left, a worn
/// highlight along the top edge and a hair of ring wear in the middle.
private struct SleeveFinish: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.13), location: 0),
                    .init(color: .white.opacity(0.0), location: 0.38),
                    .init(color: .black.opacity(0.0), location: 0.7),
                    .init(color: .black.opacity(0.18), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            Circle()
                .strokeBorder(.white.opacity(0.035), lineWidth: 18)
                .padding(26)
                .blendMode(.screen)

            RoundedRectangle(cornerRadius: 2.5)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2.5))
        .allowsHitTesting(false)
    }
}

// MARK: - Shelf

/// A floating oak shelf seen from just above: a sliver of lit top face and a
/// deeper front edge, with its shadow falling onto the wall below.
private struct WallShelf: View {
    var width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Top face, foreshortened to a sliver and narrowing towards the
            // wall.
            ShelfTop()
                .fill(LinearGradient(
                    colors: [Wood.light.opacity(0.75), Wood.light],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: 9)

            Rectangle()
                .fill(LinearGradient(
                    colors: [Wood.mid, Wood.dark],
                    startPoint: .top, endPoint: .bottom))
                .overlay(WoodGrain().opacity(0.5))
                .overlay(alignment: .top) {
                    Rectangle().fill(.white.opacity(0.18)).frame(height: 0.75)
                }
                .frame(width: width, height: 20)
        }
        // Shadow on the wall below, fading out downwards.
        .background(alignment: .bottom) {
            // Wide and shallow so it never shows an edge: densest right
            // under the shelf, gone well before the deck below.
            EllipticalGradient(
                stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .black.opacity(0.18), location: 0.45),
                    .init(color: .clear, location: 1),
                ],
                center: .top, startRadiusFraction: 0, endRadiusFraction: 0.55)
                .frame(width: width + 120, height: 70)
                .offset(y: 70)
        }
        .accessibilityHidden(true)
    }

    private struct ShelfTop: Shape {
        func path(in rect: CGRect) -> Path {
            let inset: CGFloat = 7
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

private enum Wood {
    static let light = Color(hex: 0x8A6243)
    static let mid = Color(hex: 0x5E3F2A)
    static let dark = Color(hex: 0x3A2618)
}

/// A few long, uneven streaks — enough to read as grain at a glance without
/// any image assets.
private struct WoodGrain: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E37_79B9
            func random() -> CGFloat {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
            }
            let lines = Int(size.height / 2.6)
            for index in 0..<lines {
                let y = (CGFloat(index) + random()) * size.height / CGFloat(lines)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                let wobble = random() * 2.4 - 1.2
                path.addCurve(
                    to: CGPoint(x: size.width, y: y + wobble),
                    control1: CGPoint(x: size.width * 0.33, y: y - wobble * 1.5),
                    control2: CGPoint(x: size.width * 0.66, y: y + wobble * 2))
                context.stroke(
                    path,
                    with: .color(.black.opacity(0.10 + random() * 0.18)),
                    lineWidth: 0.4 + random() * 0.9)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Turntable

/// Space-grey satin lacquer: dark enough to sit back behind the cover,
/// light enough that the black platter still reads against it.
private enum Lacquer {
    static let topFar = Color(hex: 0x26272B)
    static let top = Color(hex: 0x333438)
    static let front = Color(hex: 0x2C2D31)
    static let frontShade = Color(hex: 0x1A1B1E)
}

/// The deck's own 3D space. Plan `x`/`y` are canvas units on the plinth's
/// top face, measured from its back-left corner; `z` is height above that
/// face in screen points. Everything flat is drawn in plan and squashed by
/// `k`; everything that stands up off the deck — spindle, tonearm, arm rest
/// — is drawn straight in screen space through `project`, so it rises off
/// the deck instead of being flattened into it.
private enum DeckSpace {
    typealias C = TurntableStage.Canvas

    static let k = CGFloat(cos(C.deckTilt * .pi / 180))

    static func project(_ point: CGPoint, z: CGFloat = 0) -> CGPoint {
        CGPoint(x: point.x, y: point.y * k - z)
    }

    static let platterCenter = CGPoint(x: 245, y: 222)
    static let platterRadius: CGFloat = 180
    static let platterHeight: CGFloat = 16
    static let recordRadius: CGFloat = 165
    static let recordTop: CGFloat = 18

    /// A height expressed as the plan offset that lands at the same screen
    /// point, for drawing raised flat things (platter top, record) in plan.
    static func lift(_ z: CGFloat) -> CGFloat { z / k }
}

private extension View {
    /// Lays a `deckWidth × deckDepth` plan drawing onto the tipped plinth.
    func onDeckPlan() -> some View {
        let C = TurntableStage.Canvas.self
        return frame(width: C.deckWidth, height: C.deckDepth)
            .scaleEffect(x: 1, y: DeckSpace.k, anchor: .top)
            .frame(width: C.deckWidth, height: C.deckDepth * DeckSpace.k, alignment: .top)
    }
}

/// A belt-drive deck seen from the front and a little above: a slab plinth
/// on tall isolation feet, a thick platter, and a gimballed tonearm that
/// swings onto the record when playback starts and walks inward as the
/// track plays.
private struct Turntable: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var artworkID: Artwork.ID?
    var isPlaying: Bool
    var progress: Double

    private typealias C = TurntableStage.Canvas

    /// Angle at the moment of the last play/pause, and when that was. The
    /// record's angle is derived from these rather than animated, so pausing
    /// freezes it exactly where it is and playing picks up from there.
    @State private var restingAngle: Double = 0
    @State private var spinStart: Date = .now

    /// 33⅓ rpm.
    private static let degreesPerSecond = 200.0

    private var spins: Bool { isPlaying && !reduceMotion }

    private func angle(at date: Date) -> Double {
        guard spins else { return restingAngle }
        return restingAngle + date.timeIntervalSince(spinStart) * Self.degreesPerSecond
    }

    /// Clockwise from pointing straight at the viewer. Rest sits in the arm
    /// rest beside the platter; play runs from the lead-in groove to the
    /// run-out.
    private var armAngle: Double {
        isPlaying ? ArmGeometry.playStart + min(max(progress, 0), 1) * 13 : ArmGeometry.restAngle
    }

    private var projectedDepth: CGFloat { C.deckDepth * DeckSpace.k }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                plinthTop
                platter.onDeckPlan()
                TonearmAssembly(angle: armAngle)
                    .frame(width: C.deckWidth, height: projectedDepth)
                    .animation(.spring(response: 1.3, dampingFraction: 0.9), value: isPlaying)
                    .animation(.linear(duration: 1), value: progress)
            }
            .frame(width: C.deckWidth, height: projectedDepth, alignment: .topLeading)

            plinthFront
        }
        .frame(width: C.deckWidth)
        .background(alignment: .bottom) {
            EllipticalGradient(
                colors: [.black.opacity(0.8), .black.opacity(0.35), .clear],
                center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                .frame(width: C.deckWidth + 90, height: 44)
                .offset(y: 16)
        }
        .onChange(of: spins) { _, nowSpinning in
            let now = Date.now
            if nowSpinning {
                spinStart = now
            } else {
                restingAngle += now.timeIntervalSince(spinStart) * Self.degreesPerSecond
            }
        }
        .onAppear { spinStart = .now }
        .accessibilityHidden(true)
    }

    // MARK: Plinth

    /// Drawn in screen space rather than plan, as a trapezoid whose far edge
    /// is narrower than the near one: the perspective an affine squash
    /// can't give, and the main cue that the deck has depth.
    private var plinthTop: some View {
        let shape = PlinthTop(taper: 26)
        return shape
            .fill(LinearGradient(
                colors: [Lacquer.topFar, Lacquer.top],
                startPoint: .top, endPoint: .bottom))
            // Pool of the overhead light, brightest towards the back left.
            .overlay(
                EllipticalGradient(
                    colors: [.white.opacity(0.10), .white.opacity(0.03), .clear],
                    center: UnitPoint(x: 0.32, y: 0.25),
                    startRadiusFraction: 0, endRadiusFraction: 0.7)
                .clipShape(shape))
            // A broad, soft window reflection across the satin finish.
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0), location: 0.25),
                        .init(color: .white.opacity(0.07), location: 0.5),
                        .init(color: .white.opacity(0), location: 0.75),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(shape))
            // The near edge catches the light where top meets front.
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.white.opacity(0.08), .white.opacity(0.4), .white.opacity(0.08)],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1.2)
            }
            .frame(width: C.deckWidth, height: projectedDepth)
    }

    private var plinthFront: some View {
        ZStack(alignment: .top) {
            HStack {
                IsolationFoot()
                Spacer()
                IsolationFoot()
            }
            .padding(.horizontal, 92)
            .padding(.top, 26)

            UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                .fill(LinearGradient(
                    colors: [Lacquer.front, Lacquer.frontShade],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0), location: 0.1),
                            .init(color: .white.opacity(0.05), location: 0.45),
                            .init(color: .white.opacity(0), location: 0.75),
                        ],
                        startPoint: .leading, endPoint: .trailing))
                .frame(height: C.deckFront)
        }
        .frame(height: C.deckFront + 22, alignment: .top)
    }

    // MARK: Platter

    private var platter: some View {
        let center = DeckSpace.platterCenter
        let r = DeckSpace.platterRadius
        let platterRise = DeckSpace.lift(DeckSpace.platterHeight)
        let recordRise = DeckSpace.lift(DeckSpace.recordTop)
        let recordDiameter = DeckSpace.recordRadius * 2

        return ZStack(alignment: .topLeading) {
            Color.clear

            // Contact shadow where the platter's skirt meets the plinth.
            Circle()
                .fill(RadialGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.25), .clear],
                    center: .center, startRadius: r * 0.8, endRadius: r + 22))
                .frame(width: (r + 22) * 2, height: (r + 22) * 2)
                .position(x: center.x + 6, y: center.y + 10)

            // The platter's machined edge: a thick, matte band lit from the
            // upper left.
            Cylinder(rise: platterRise)
                .fill(LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x0C0C0E), location: 0),
                        .init(color: Color(hex: 0x2C2C30), location: 0.3),
                        .init(color: Color(hex: 0x1A1A1D), location: 0.6),
                        .init(color: Color(hex: 0x09090A), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: r * 2, height: r * 2 + platterRise)
                .position(x: center.x, y: center.y - platterRise / 2)

            // Felt-matte platter top, showing as a rim around the record.
            Circle()
                .fill(Color(hex: 0x1F1F22))
                .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 2))
                .frame(width: r * 2, height: r * 2)
                .position(x: center.x, y: center.y - platterRise)

            // The record's own edge, a hair proud of the platter.
            Cylinder(rise: recordRise - platterRise)
                .fill(Color(hex: 0x050506))
                .frame(width: recordDiameter, height: recordDiameter + recordRise - platterRise)
                .position(x: center.x, y: center.y - (platterRise + recordRise) / 2)

            TimelineView(.animation(paused: !spins)) { context in
                VinylRecord(artworkID: artworkID, diameter: recordDiameter)
                    .rotationEffect(.degrees(angle(at: context.date)))
            }
            .position(x: center.x, y: center.y - recordRise)

            // Studio light caught in the grooves. Stays put while the record
            // turns beneath it, which is what sells the spin.
            GrooveSheen(diameter: recordDiameter)
                .position(x: center.x, y: center.y - recordRise)

            // The record's rim, lit along the far side by the overhead light
            // and falling into shadow towards the viewer.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.32), .white.opacity(0.06), .clear],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 2.5)
                .frame(width: recordDiameter, height: recordDiameter)
                .position(x: center.x, y: center.y - recordRise)

            // Platter rim catches the same light.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .clear],
                        startPoint: .top, endPoint: .center),
                    lineWidth: 3)
                .frame(width: r * 2, height: r * 2)
                .position(x: center.x, y: center.y - platterRise)
        }
    }

}

/// The plinth's top face in screen space: full width at the near edge,
/// `taper` in from each side at the far one.
private struct PlinthTop: Shape {
    var taper: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + taper, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - taper, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// An upright disc seen from above: a top face and a bottom face joined by
/// the side, filling its frame. The caller sets `rise` to the plan distance
/// between the two faces.
private struct Cylinder: Shape {
    var rise: CGFloat

    func path(in rect: CGRect) -> Path {
        let side = rect.width
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX, y: rect.minY, width: side, height: side))
        path.addEllipse(in: CGRect(x: rect.minX, y: rect.maxY - side, width: side, height: side))
        path.addRect(CGRect(x: rect.minX, y: rect.minY + side / 2, width: side, height: rise))
        return path
    }
}

private struct GrooveSheen: View {
    var diameter: CGFloat

    var body: some View {
        Circle()
            .fill(AngularGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0.0),
                    .init(color: .white.opacity(0.26), location: 0.08),
                    .init(color: .white.opacity(0), location: 0.17),
                    .init(color: .white.opacity(0), location: 0.5),
                    .init(color: .white.opacity(0.18), location: 0.58),
                    .init(color: .white.opacity(0), location: 0.67),
                    .init(color: .white.opacity(0), location: 1),
                ],
                center: .center, angle: .degrees(-60)))
            .mask {
                // Grooves only — the label is paper and stays matte.
                Circle()
                    .strokeBorder(.white, lineWidth: diameter * 0.31)
                    .padding(diameter * 0.03)
            }
            .frame(width: diameter, height: diameter)
            .blendMode(.screen)
            .allowsHitTesting(false)
    }
}

/// Tall damped cone foot, the kind that lifts a slab plinth well clear of
/// the shelf.
private struct IsolationFoot: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(hex: 0x050506), Color(hex: 0x1E1E21), Color(hex: 0x0A0A0B)],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: 60, height: 12)
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(
                    colors: [Color(hex: 0x0A0A0B), Color(hex: 0x2A2A2E), Color(hex: 0x0C0C0D)],
                    startPoint: .leading, endPoint: .trailing))
                .overlay(alignment: .top) {
                    Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                }
                .frame(width: 74, height: 12)
        }
    }
}

// MARK: - Tonearm

/// Where every part of the arm is for a given swing angle, in deck space.
private struct ArmGeometry {
    static let pivot = CGPoint(x: 505, y: 110)
    static let length: CGFloat = 250
    static let pivotZ: CGFloat = 36
    static let restAngle = 3.0
    static let playStart = 33.0
    /// Headshell height while parked on the arm rest, and while tracking.
    static let restTipZ: CGFloat = 23
    static let playTipZ: CGFloat = DeckSpace.recordTop + 8
    /// Real headshells are angled in towards the spindle.
    static let headshellOffset = 23.0

    var angle: Double

    private var radians: Double { angle * .pi / 180 }
    var direction: CGVector { CGVector(dx: -sin(radians), dy: cos(radians)) }

    /// 0 parked on the rest, 1 lowered onto the record. The cue lift drops
    /// the arm as it swings over the platter.
    private var lowered: CGFloat {
        CGFloat(min(max((angle - Self.restAngle) / (Self.playStart - Self.restAngle), 0), 1))
    }

    var tipZ: CGFloat { Self.restTipZ + (Self.playTipZ - Self.restTipZ) * lowered }

    /// Plan point `s` along the arm from the pivot (negative is behind it).
    func plan(_ s: CGFloat) -> CGPoint {
        CGPoint(x: Self.pivot.x + direction.dx * s, y: Self.pivot.y + direction.dy * s)
    }

    /// The arm tube's height at `s`, sloping from the bearing down to the
    /// headshell.
    func height(at s: CGFloat) -> CGFloat {
        guard s > 0 else { return Self.pivotZ }
        return Self.pivotZ + (tipZ - Self.pivotZ) * min(s / Self.length, 1)
    }

    func screen(_ s: CGFloat) -> CGPoint {
        DeckSpace.project(plan(s), z: height(at: s))
    }

    var headshellDirection: CGVector {
        let phi = Self.headshellOffset * .pi / 180
        return CGVector(
            dx: direction.dx * cos(phi) - direction.dy * sin(phi),
            dy: direction.dx * sin(phi) + direction.dy * cos(phi))
    }

    static let neck: CGFloat = length - 32
}

/// One moving piece of the tonearm, as a `Shape` so the swing animates
/// smoothly through every intermediate angle rather than jumping.
private struct ArmPart: Shape {
    enum Part { case tube, tubeHighlight, shadow }

    var angle: Double
    var part: Part

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let arm = ArmGeometry(angle: angle)
        var path = Path()

        switch part {
        case .tube:
            // One straight tube right through the bearing, from the
            // counterweight stub to the headshell.
            path.move(to: DeckSpace.project(arm.plan(-17), z: ArmGeometry.pivotZ))
            path.addLine(to: arm.screen(ArmGeometry.neck + 2))

        case .tubeHighlight:
            path.move(to: arm.screen(16).applying(.init(translationX: -0.4, y: -1.9)))
            path.addLine(to: arm.screen(ArmGeometry.neck).applying(.init(translationX: -0.4, y: -1.9)))

        case .shadow:
            // Cast down and to the right onto whatever is beneath: the
            // plinth near the pivot, the record further out.
            let start = DeckSpace.project(arm.plan(20), z: 0)
            let end = DeckSpace.project(arm.plan(ArmGeometry.length - 6), z: DeckSpace.recordTop * 0.8)
            path.move(to: start.applying(.init(translationX: 14, y: 6)))
            path.addLine(to: end.applying(.init(translationX: 8, y: 4)))

        }
        return path
    }
}

/// Matte black anodised metal: the one material every part of the arm
/// shares. Highlights stay low so the arm sits quietly on the deck.
private enum Metal {
    static let light = Color(hex: 0x55575D)
    static let mid = Color(hex: 0x2B2C30)
    static let dark = Color(hex: 0x111113)

    /// Lit from the upper left, for anything round seen side-on.
    static var cylinder: LinearGradient {
        LinearGradient(colors: [dark, light, mid, dark], startPoint: .leading, endPoint: .trailing)
    }

    /// Lit from above, for faces seen end-on.
    static var face: LinearGradient {
        LinearGradient(colors: [light, mid], startPoint: .top, endPoint: .bottom)
    }
}

/// The tonearm, drawn in screen space: one pillar, one tube, one
/// counterweight, one headshell, all the same matte black.
///
/// Animatable itself, not only through `ArmPart`, because the counterweight
/// and headshell are drawn in a `Canvas` with gradients pinned to where each
/// part is on screen. A `Shape` fill would stretch its gradient over the
/// whole deck, which is what left those parts looking flat.
private struct TonearmAssembly: View, @preconcurrency Animatable {
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    private static let base = DeckSpace.project(ArmGeometry.pivot)
    private static let bearing = DeckSpace.project(ArmGeometry.pivot, z: ArmGeometry.pivotZ)
    private static let spindle = DeckSpace.platterCenter

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            ArmPart(angle: angle, part: .shadow)
                .stroke(.black.opacity(0.32), style: StrokeStyle(lineWidth: 6, lineCap: .round))

            spindle
            // Behind the bearing pillar, so the pillar overlaps it.
            Canvas { context, _ in
                Self.drawCounterweight(in: &context, arm: ArmGeometry(angle: angle))
            }
            pillar(at: Self.base, height: ArmGeometry.pivotZ + 6, width: 24)

            // Round tube: a dark underside, the body, then a thin lit top.
            ArmPart(angle: angle, part: .tube)
                .stroke(Metal.dark, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            ArmPart(angle: angle, part: .tube)
                .offset(y: -0.7)
                .stroke(Metal.mid, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            ArmPart(angle: angle, part: .tubeHighlight)
                .stroke(Metal.light, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            Canvas { context, _ in
                Self.drawHeadshell(in: &context, arm: ArmGeometry(angle: angle))
            }
        }
    }

    // MARK: Counterweight

    /// A short cylinder on the tube behind the bearing, drawn in its own
    /// frame along the arm: shaded across its round side, lit from above,
    /// with a slightly lighter end face where it meets the bearing.
    private static func drawCounterweight(in context: inout GraphicsContext, arm: ArmGeometry) {
        let radius: CGFloat = 9
        let front = DeckSpace.project(arm.plan(-16), z: ArmGeometry.pivotZ)
        let back = DeckSpace.project(arm.plan(-40), z: ArmGeometry.pivotZ)
        // Always run the local x axis left to right, so local -y is up.
        let (from, to) = back.x >= front.x ? (front, back) : (back, front)
        let length = hypot(to.x - from.x, to.y - from.y)

        var local = context
        local.translateBy(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        local.rotate(by: .radians(atan2(to.y - from.y, to.x - from.x)))

        let body = CGRect(x: -length / 2, y: -radius, width: length, height: 2 * radius)
        local.fill(
            Path(roundedRect: body, cornerSize: CGSize(width: 3.5, height: 3.5)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0x4A4C52), location: 0),
                    .init(color: Color(hex: 0x6E7076), location: 0.22),
                    .init(color: Metal.mid, location: 0.55),
                    .init(color: Metal.dark, location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: -radius), endPoint: CGPoint(x: 0, y: radius)))

        // Machined grooves near each end, as on a real weight.
        for x in [-length / 2 + 4, length / 2 - 4] {
            var groove = Path()
            groove.move(to: CGPoint(x: x, y: -radius + 1))
            groove.addLine(to: CGPoint(x: x, y: radius - 1))
            local.stroke(groove, with: .color(.black.opacity(0.45)), lineWidth: 0.8)
        }
    }

    // MARK: Headshell

    /// A thin plate with real thickness, and the cartridge hanging under its
    /// tip, each drawn as a small prism so the sides catch less light than
    /// the top.
    private static func drawHeadshell(in context: inout GraphicsContext, arm: ArmGeometry) {
        let neck = arm.plan(ArmGeometry.neck)
        let heading = arm.headshellDirection
        let normal = CGVector(dx: -heading.dy, dy: heading.dx)
        let z = arm.tipZ

        func plan(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: neck.x + heading.dx * along + normal.dx * across,
                    y: neck.y + heading.dy * along + normal.dy * across)
        }

        // Cartridge first: it sits under the plate.
        let cartridge = [plan(20, -5), plan(35, -5.5), plan(35, 5.5), plan(20, 5)]
        prism(cartridge, top: z - 1, bottom: z - 8, in: &context,
              top: .color(Metal.mid), side: Color(hex: 0x141416))

        let shell = [plan(0, -3.5), plan(38, -7), plan(38, 7), plan(0, 3.5)]
        let tip = DeckSpace.project(plan(38, 0), z: z)
        let root = DeckSpace.project(plan(0, 0), z: z)
        prism(shell, top: z, bottom: z - 3.5, in: &context,
              top: .linearGradient(
                  Gradient(colors: [Metal.mid, Color(hex: 0x66686E), Metal.light]),
                  startPoint: root, endPoint: tip),
              side: Color(hex: 0x111113))

        // A thin lit edge along the near side, where the plate turns down.
        var edge = Path()
        edge.move(to: DeckSpace.project(shell[3], z: z))
        edge.addLine(to: DeckSpace.project(shell[2], z: z))
        let nearSide = DeckSpace.project(shell[2], z: z).y > DeckSpace.project(shell[1], z: z).y
        if !nearSide {
            edge = Path()
            edge.move(to: DeckSpace.project(shell[0], z: z))
            edge.addLine(to: DeckSpace.project(shell[1], z: z))
        }
        context.stroke(edge, with: .color(Metal.light.opacity(0.7)), lineWidth: 0.8)
    }

    /// Fills a flat-topped block: its sides in `side`, then its top over
    /// them, so only the faces turned towards the viewer show.
    private static func prism(_ outline: [CGPoint], top topZ: CGFloat, bottom bottomZ: CGFloat,
                              in context: inout GraphicsContext,
                              top topShading: GraphicsContext.Shading, side: Color) {
        let upper = outline.map { DeckSpace.project($0, z: topZ) }
        let lower = outline.map { DeckSpace.project($0, z: bottomZ) }
        var sides = Path()
        for i in outline.indices {
            let j = (i + 1) % outline.count
            sides.addLines([upper[i], upper[j], lower[j], lower[i]])
            sides.closeSubpath()
        }
        sides.addLines(lower)
        sides.closeSubpath()
        context.fill(sides, with: .color(side))

        var face = Path()
        face.addLines(upper)
        face.closeSubpath()
        context.fill(face, with: topShading)
    }

    private static func unit(_ v: CGVector) -> CGVector {
        let length = max(hypot(v.dx, v.dy), 0.0001)
        return CGVector(dx: v.dx / length, dy: v.dy / length)
    }

    /// An upright aluminium cylinder standing on the plinth, with its lit
    /// top face showing.
    private func pillar(at foot: CGPoint, height: CGFloat, width: CGFloat) -> some View {
        let cap = width * DeckSpace.k
        return ZStack {
            Rectangle()
                .fill(Metal.cylinder)
                .frame(width: width, height: height)
                .position(x: foot.x, y: foot.y - height / 2)
            Ellipse()
                .fill(Metal.cylinder)
                .frame(width: width, height: cap)
                .position(foot)
            Ellipse()
                .fill(Metal.light)
                .frame(width: width, height: cap)
                .position(x: foot.x, y: foot.y - height)
        }
    }

    private var spindle: some View {
        let foot = DeckSpace.project(Self.spindle, z: DeckSpace.recordTop)
        // Bare steel, so it still shows against the black arm and record.
        return Capsule()
            .fill(LinearGradient(
                colors: [Color(hex: 0x6A6A72), Color(hex: 0xEDEDF2), Color(hex: 0x6A6A72)],
                startPoint: .leading, endPoint: .trailing))
            .frame(width: 6, height: 12)
            .position(x: foot.x, y: foot.y - 5)
    }
}

/// Black vinyl with fine grooves, a lead-in band, the run-out, and the cover
/// itself as the centre label.
private struct VinylRecord: View {
    var artworkID: Artwork.ID?
    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color(hex: 0x1C1C20), Color(hex: 0x0A0A0C)],
                    center: .center, startRadius: 0, endRadius: diameter / 2))

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = size.width / 2 - 4
                let inner = size.width * 0.19
                var radius = inner
                var index = 0
                while radius < outer {
                    let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)
                    // Every so often a slightly brighter ring, so the record
                    // shows track gaps the way a real side does.
                    let bright = index % 23 == 0
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(bright ? 0.09 : 0.035)),
                        lineWidth: bright ? 1.1 : 0.5)
                    radius += 1.6
                    index += 1
                }
            }

            // An off-centre highlight that turns with the record, so the spin
            // is visible even on a cover with no strong features.
            Ellipse()
                .fill(.white.opacity(0.05))
                .frame(width: diameter * 0.18, height: diameter * 0.42)
                .offset(x: diameter * 0.3)
                .blur(radius: 6)

            ArtworkView(
                artworkID: artworkID,
                isCircular: true,
                caption: nil,
                displaySize: 160
            )
            .frame(width: diameter * 0.34, height: diameter * 0.34)
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}


private func + (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x + vector.dx, y: point.y + vector.dy)
}

private func - (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x - vector.dx, y: point.y - vector.dy)
}

private func * (vector: CGVector, scale: CGFloat) -> CGVector {
    CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
}
