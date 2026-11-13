import SwiftUI
import CadenceDesign
import CadenceCore

/// The window's own chrome. The mock paints three traffic-light circles; a
/// native window with `.hiddenTitleBar` already has real ones, so this reserves
/// their space instead of drawing imitations.
struct TitleBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        @Bindable var model = model

        HStack(spacing: Tokens.Space.l) {
            Color.clear.frame(width: Tokens.Layout.trafficLightInset, height: 1)

            HStack(spacing: Tokens.Space.xs) {
                NavigationChevron(direction: .backward, isEnabled: model.canGoBack) {
                    model.goBack()
                }
                NavigationChevron(direction: .forward, isEnabled: model.canGoForward) {
                    model.goForward()
                }
            }

            HStack(spacing: Tokens.Space.s) {
                SearchTrigger()
                    .frame(maxWidth: Tokens.Layout.searchFieldMaxWidth)
                PlaySomethingDie()
            }
            .frame(maxWidth: .infinity)

            // Balances the chevrons on the left so the field stays optically
            // centred, and gives Preferences a way in besides ⌘,.
            HStack(spacing: Tokens.Space.xs) {
                Spacer(minLength: 0)
                IconButton(systemImage: "gearshape", label: "Preferences",
                           glyphSize: 13, side: 26,
                           isActive: model.screen == .settings) {
                    if model.screen != .settings { model.show(.settings) }
                }
            }
            .frame(width: 92)
        }
        .padding(.horizontal, Tokens.Space.l)
        .frame(height: Tokens.Layout.titleBarHeight)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: 0x1F1F24))
                .frame(height: 1)
        }
        .background(Tokens.Palette.chrome)
    }
}

private struct NavigationChevron: View {
    enum Direction { case backward, forward }

    var direction: Direction
    var isEnabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            CadenceIcon(direction == .backward ? "chevron.left" : "chevron.right", size: 12)
                .foregroundStyle(isEnabled
                                 ? (isHovering ? Color(hex: 0xC9C9D2) : Color(hex: 0x6E6E78))
                                 : Color(hex: 0x43434C))
                .frame(width: 26, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .fill(isEnabled && isHovering ? Color(hex: 0x1E1E24) : .clear)
                }
        }
        .plainControl()
        .disabled(!isEnabled)
        .animatedHover($isHovering)
        .accessibilityLabel(direction == .backward ? "Back" : "Forward")
    }
}

// MARK: - Just play something

/// "Just play something": a die that picks an album from the library at
/// random and plays it from track 1. Playback starts on the click; the roll
/// is decoration on top, and also plays when ⌘J makes the pick.
private struct PlaySomethingDie: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false
    @State private var rolls = 0
    /// The face showing at rest.
    @State private var face = 5
    /// Where each number sits on the cube for the current roll.
    @State private var cube = DieCube(front: 5, result: 5)
    @State private var landing: Task<Void, Never>?

    private var isEnabled: Bool { !model.albums.isEmpty }

    private static let rollDuration = 1.83
    /// Sized so the die's face stands nearly as tall as the search field.
    nonisolated static let glyphSize: CGFloat = 32
    nonisolated static var box: CGFloat { glyphSize * CadenceIcon.boxScale }

    var body: some View {
        Button { model.justPlaySomething(on: playback) } label: {
            let face = face, cube = cube
            Color.clear
                .frame(width: Self.box, height: Self.box)
                .keyframeAnimator(initialValue: Tumble(), trigger: rolls) { content, tumble in
                    content.overlay {
                        Group {
                            if tumble.isAtRest {
                                CadenceIcon("die.face.\(face)", size: Self.glyphSize)
                            } else if tumble.hasLanded(on: cube) {
                                CadenceIcon("die.face.\(cube.result)", size: Self.glyphSize)
                            } else {
                                TumblingDie(cube: cube, tumble: tumble)
                                    // Room for corners swinging out mid-roll.
                                    .frame(width: Self.box * 1.6, height: Self.box * 1.6)
                            }
                        }
                        .scaleEffect(tumble.scale)
                        .offset(y: tumble.lift)
                    }
                } keyframes: { _ in
                    // Wind up, tumble end over end for two turns plus the
                    // quarter or half turn that brings the result to the
                    // front, with a full turn sideways and a wobble, then
                    // settle. Reduce Motion keeps only a gentle press.
                    let motion = reduceMotion ? 0.0 : 1.0
                    let pitch = (720 + cube.finalPitch) * motion
                    KeyframeTrack(\.pitch) {
                        CubicKeyframe(-18 * motion, duration: 0.18)
                        CubicKeyframe(pitch + 20 * motion, duration: 1.15)
                        SpringKeyframe(pitch, duration: 0.5, spring: .bouncy)
                    }
                    KeyframeTrack(\.yaw) {
                        CubicKeyframe(10 * motion, duration: 0.18)
                        CubicKeyframe(372 * motion, duration: 1.15)
                        SpringKeyframe(360 * motion, duration: 0.5, spring: .bouncy)
                    }
                    KeyframeTrack(\.roll) {
                        CubicKeyframe(-12 * motion, duration: 0.18)
                        CubicKeyframe(25 * motion, duration: 0.6)
                        CubicKeyframe(0, duration: 0.55)
                        SpringKeyframe(0, duration: 0.5)
                    }
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(0.82, duration: 0.18)
                        CubicKeyframe(1 + 0.12 * motion, duration: 0.45)
                        CubicKeyframe(1, duration: 0.7)
                        SpringKeyframe(1, duration: 0.5)
                    }
                    KeyframeTrack(\.lift) {
                        CubicKeyframe(1.5 * motion, duration: 0.18)
                        CubicKeyframe(-5 * motion, duration: 0.45)
                        CubicKeyframe(0, duration: 0.7)
                        SpringKeyframe(0, duration: 0.5)
                    }
                }
                .foregroundStyle(!isEnabled ? Color(hex: 0x43434C)
                                 : (isHovering ? Color(hex: 0xEDEDF2) : Color(hex: 0x7A7A85)))
                // A bare glyph, no chrome; the hit area still spans the
                // search field's height.
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .plainControl()
        .disabled(!isEnabled)
        .animatedHover($isHovering)
        .onChange(of: model.somethingPlayed) { roll() }
        .accessibilityLabel("Just play something")
        .help("Just play something (⌘J)")
    }

    private func roll() {
        // Lands only on the faces with the nicest-looking pips; the others
        // still flash past mid-roll.
        let result = [3, 5, 6].randomElement()!
        cube = DieCube(front: face, result: result)
        if reduceMotion { face = result }
        rolls += 1

        // The resting face catches up just before the roll ends, so the die
        // never flicks back to its old face when the animator lets go.
        landing?.cancel()
        landing = Task {
            try? await Task.sleep(for: .seconds(Self.rollDuration - 0.05))
            if !Task.isCancelled { face = result }
        }
    }

    struct Tumble {
        /// Degrees about the horizontal axis (end over end).
        var pitch: Double = 0
        /// Degrees about the vertical axis.
        var yaw: Double = 0
        /// Degrees about the axis pointing at the viewer.
        var roll: Double = 0
        var scale: Double = 1
        var lift: Double = 0

        var isAtRest: Bool { pitch == 0 && yaw == 0 && roll == 0 }

        func hasLanded(on cube: DieCube) -> Bool {
            pitch == 720 + cube.finalPitch && yaw == 360 && roll == 0
        }
    }
}

/// Which number sits on which side of the cube for one roll. The old face
/// starts at the front; the result sits wherever a final quarter or half
/// turn end over end brings it to the front. Opposite faces sum to seven.
struct DieCube: Equatable {
    /// Numbers on the +z, -z, +x, -x, +y, -y faces, in that order.
    var faces: [Int]
    var result: Int
    /// Extra pitch past two whole turns: 0, 90 or 180 degrees.
    var finalPitch: Double

    init(front: Int, result: Int) {
        self.result = result
        let pairs = [(1, 6), (2, 5), (3, 4)].filter { $0.0 != front && $0.1 != front }.shuffled()
        func oriented(_ pair: (Int, Int)) -> (Int, Int) { Bool.random() ? pair : (pair.1, pair.0) }

        var top: (Int, Int), side: (Int, Int)
        if result == front {
            finalPitch = 0
            (top, side) = (oriented(pairs[0]), oriented(pairs[1]))
        } else if result == 7 - front {
            finalPitch = 180
            (top, side) = (oriented(pairs[0]), oriented(pairs[1]))
        } else {
            // A quarter turn brings the top face to the front.
            finalPitch = 90
            top = (result, 7 - result)
            side = oriented(pairs.first { $0.0 != result && $0.1 != result }!)
        }
        faces = [front, 7 - front, side.0, side.1, top.0, top.1]
    }
}

/// The die mid-roll: a cube in perspective, drawn in the icon set's line
/// style. Faces turned toward the viewer are drawn, shaded by how far they
/// are turned away; face-on it matches the `die.face.N` glyph exactly.
private struct TumblingDie: View {
    var cube: DieCube
    var tumble: PlaySomethingDie.Tumble

    private typealias Vec = SIMD3<Double>

    /// Per face: centre (= outward normal), then the face's own right and
    /// down axes, so pips land the way the glyphs draw them when face-on.
    private static let frames: [(n: Vec, u: Vec, v: Vec)] = [
        (Vec(0, 0, 1), Vec(1, 0, 0), Vec(0, -1, 0)),
        (Vec(0, 0, -1), Vec(-1, 0, 0), Vec(0, -1, 0)),
        (Vec(1, 0, 0), Vec(0, 0, -1), Vec(0, -1, 0)),
        (Vec(-1, 0, 0), Vec(0, 0, 1), Vec(0, -1, 0)),
        (Vec(0, 1, 0), Vec(1, 0, 0), Vec(0, 0, 1)),
        (Vec(0, -1, 0), Vec(1, 0, 0), Vec(0, 0, -1)),
    ]

    /// Glyph geometry on the 24-unit artboard, in face units (half side 7.5).
    private static let pipOffset = 3.1 / 7.5
    private static let pipRadius = 1.25 / 7.5
    private static let cornerRadius = 3.6 / 7.5
    /// Camera distance in face units: close enough to read as 3D.
    nonisolated private static let camera = 4.5

    private static func pips(_ n: Int) -> [SIMD2<Double>] {
        let k = pipOffset
        switch n {
        case 1: return [.zero]
        case 2: return [[k, -k], [-k, k]]
        case 3: return [[k, -k], .zero, [-k, k]]
        case 4: return [[-k, -k], [k, -k], [-k, k], [k, k]]
        case 5: return [[-k, -k], [k, -k], .zero, [-k, k], [k, k]]
        default: return [[-k, -k], [-k, 0], [-k, k], [k, -k], [k, 0], [k, k]]
        }
    }

    /// The face outline as the glyph draws it, a rounded square.
    private static let outline: [SIMD2<Double>] = {
        let r = cornerRadius, inner = 1 - r
        let corners: [(SIMD2<Double>, Double)] = [
            ([inner, -inner], -.pi / 2), ([inner, inner], 0),
            ([-inner, inner], .pi / 2), ([-inner, -inner], .pi),
        ]
        return corners.flatMap { centre, start in
            (0...5).map { step in
                let angle = start + Double(step) / 5 * .pi / 2
                return centre + r * SIMD2(cos(angle), sin(angle))
            }
        }
    }()

    var body: some View {
        Canvas { context, size in
            let rotate = rotation()
            // Face-on, the cube's half side matches the glyph's (7.5 of 24
            // units of the icon box).
            let box = PlaySomethingDie.box
            let half = box * 7.5 / 24
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let stroke = StrokeStyle(lineWidth: box * CadenceGlyph.dieStrokeWidth / 24,
                                     lineCap: .round, lineJoin: .round)

            func project(_ p: Vec) -> CGPoint {
                let q = rotate(p)
                let scale = (Self.camera - 1) / (Self.camera - q.z) * half
                return CGPoint(x: centre.x + q.x * scale, y: centre.y - q.y * scale)
            }

            for (index, frame) in Self.frames.enumerated() {
                let normal = rotate(frame.n)
                // Visible when the face points toward the camera, which
                // with perspective is not quite the same as normal.z > 0.
                let toCamera = Vec(0, 0, Self.camera) - normal
                guard (normal * toCamera).sum() > 0.02 else { continue }

                func point(_ uv: SIMD2<Double>) -> CGPoint {
                    project(frame.n + frame.u * uv.x + frame.v * uv.y)
                }
                var face = Path()
                face.addLines(Self.outline.map(point))
                face.closeSubpath()

                var shaded = context
                shaded.opacity = 0.3 * (1 - max(0, normal.z))
                shaded.fill(face, with: .foreground)
                context.stroke(face, with: .foreground, style: stroke)

                for pip in Self.pips(cube.faces[index]) {
                    var dot = Path()
                    dot.addLines((0..<12).map { step in
                        let angle = Double(step) / 12 * 2 * .pi
                        return point(pip + Self.pipRadius * SIMD2(cos(angle), sin(angle)))
                    })
                    dot.closeSubpath()
                    context.fill(dot, with: .foreground)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Pitch, then yaw, then roll, so the landing pitch alone decides
    /// which face ends up at the front.
    private func rotation() -> (Vec) -> Vec {
        let (px, py, pz) = (tumble.pitch * .pi / 180, tumble.yaw * .pi / 180, tumble.roll * .pi / 180)
        let (cx, sx, cy, sy, cz, sz) = (cos(px), sin(px), cos(py), sin(py), cos(pz), sin(pz))
        return { p in
            let a = Vec(p.x, p.y * cx - p.z * sx, p.y * sx + p.z * cx)
            let b = Vec(a.x * cy + a.z * sy, a.y, -a.x * sy + a.z * cy)
            return Vec(b.x * cz - b.y * sz, b.x * sz + b.y * cz, b.z)
        }
    }
}

// MARK: - Search

/// The title bar's own half of search: a static button that opens
/// `SearchModal`, which owns the text field itself — the Spotify/Claude
/// command-palette pattern, not a field with a dropdown hanging off it.
struct SearchTrigger: View {
    @Environment(AppModel.self) private var model
    // Optional so the snapshot, a11y and benchmark harnesses can host this
    // view without one — same reasoning as `TextEntryMonitor`'s environment.
    @Environment(SearchFocusRequester.self) private var focusRequester: SearchFocusRequester?
    @State private var isHovering = false

    var body: some View {
        Button {
            model.isSearching = true
            focusRequester?.requestFocus()
        } label: {
            HStack(spacing: Tokens.Space.s + 2) {
                CadenceIcon("magnifyingglass", size: 11)
                    .foregroundStyle(Color(hex: 0x7A7A85))
                Text("Search artists, albums, tracks, playlists, catalogs")
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundStyle(Color(hex: 0x7A7A85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(model.isSearching || isHovering
                          ? Tokens.Palette.fieldFocusBackground
                          : Tokens.Palette.fieldBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(model.isSearching
                                  ? Tokens.Palette.fieldFocusBorder
                                  : Tokens.Palette.fieldBorder, lineWidth: 1)
            }
        }
        .plainControl()
        .animatedHover($isHovering)
        .accessibilityLabel("Search library")
    }
}

