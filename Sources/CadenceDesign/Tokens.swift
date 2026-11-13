import SwiftUI
import CoreText
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Every value in the interface comes from here, on the Mac and on iOS: this
/// module is the one piece of the design the two apps share by importing it.
/// It holds what is true of Cadence anywhere (palette, spacing, radii, type,
/// motion). Sizes that belong to one platform's layout live in that app; the
/// Mac's are `Tokens.Layout`, in the app target.
///
/// Every value in the interface comes from here. Views reference tokens, never
/// literals, so when the design shifts one file changes — see PLAN.md §6.
///
/// The values are lifted from `Cadence.dc.html`, the design canvas. Where the
/// mock and native macOS disagree, the comment says which won and why.
public enum Tokens {

    // MARK: - Palette

    /// Dark only, as the design is. Should a light appearance ever be wanted,
    /// this is the one type that has to change.
    public enum Palette {
        /// The window's own ground.
        public static let surface = Color(hex: 0x0E0E11)
        /// Title bar.
        public static let chrome = Color(hex: 0x131317)
        /// Sidebar and now-playing pane — a step darker than the content.
        public static let panel = Color(hex: 0x101014)
        /// A grouped card sitting *on* the content surface — the Preferences
        /// sections. A step lighter than `surface`, so the group reads as
        /// raised rather than cut into the background.
        public static let card = Color(hex: 0x141418)
        /// Behind the immersive view.
        public static let immersiveTop = Color(hex: 0x171315)
        public static let immersiveBottom = Color(hex: 0x08080A)

        public static let accent = Color(hex: 0xE8483F)
        public static let accentHover = Color(hex: 0xF4574E)
        public static let accentDim = Color(hex: 0xE8483F).opacity(0.09)
        public static let accentEdge = Color(hex: 0xE8483F).opacity(0.40)

        public static let textPrimary = Color(hex: 0xF2F2F6)
        public static let textSecondary = Color(hex: 0x9B9BA5)
        public static let textTertiary = Color(hex: 0x8F8F99)
        /// Mono section labels — LIBRARY, UP NEXT, TITLE.
        public static let textMuted = Color(hex: 0x84848E)
        public static let textFaint = Color(hex: 0x7A7A83)

        public static let border = Color(hex: 0x1E1E23)
        public static let borderStrong = Color(hex: 0x2C2C34)
        public static let separator = Color(hex: 0x1D1D23)

        /// Track and artist rows.
        public static let rowHover = Color(hex: 0x16161B)
        /// The row that is playing.
        public static let rowActive = Color(hex: 0x17171C)
        public static let navHover = Color(hex: 0x1B1B21)
        public static let navActive = Color(hex: 0x1E1E25)

        public static let fieldBackground = Color(hex: 0x1B1B21)
        public static let fieldBorder = Color(hex: 0x2B2B33)
        public static let fieldFocusBackground = Color(hex: 0x1F1F26)
        public static let fieldFocusBorder = Color(hex: 0x3D3D48)

        public static let popover = Color(hex: 0x17171C)
        public static let popoverBorder = Color(hex: 0x2B2B33)
        /// The row wash on a popover. Lighter than `rowHover`, which is a step
        /// *darker* than the content behind it and disappears entirely on the
        /// popover's own ground. Shared by the search results and the actions
        /// menu, so the two cannot drift.
        public static let popoverHover = Color(hex: 0x1F1F26)

        public static let trackGroove = Color(hex: 0x24242B)

        /// The two stripes of the placeholder artwork hatch.
        public static let placeholderLight = Color(hex: 0x24242B)
        public static let placeholderDark = Color(hex: 0x1B1B21)
        public static let placeholderBorder = Color(hex: 0x2A2A32)
    }

    // MARK: - Space

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 26
        /// The horizontal inset every content screen shares.
        public static let contentInset: CGFloat = 32
        public static let albumInset: CGFloat = 40
        public static let paneInset: CGFloat = 20
    }

    // MARK: - Radius

    public enum Radius {
        public static let thumb: CGFloat = 4
        public static let control: CGFloat = 6
        public static let row: CGFloat = 7
        public static let card: CGFloat = 8
        public static let popover: CGFloat = 10
        public static let panel: CGFloat = 14
    }

    // MARK: - Layout

    /// The design specifies Manrope and IBM Plex Mono. Both are registered from
    /// the app bundle at launch when the files are present; when they are not,
    /// every call falls back to the system face at the same size and weight, so
    /// the app runs either way and only the texture changes.
    public enum Typography {
        /// `relativeTo: .body` makes every size below scale with the system
        /// text size (System Settings > Accessibility > Display > Larger
        /// Text) — a `fixedSize` custom font, or a plain `.system(size:)`,
        /// stays the same physical size no matter what the user has chosen.
        /// On the Mac the fallback path names the system face by its actual
        /// PostScript name (e.g. `.AppleSystemUIFontMedium`) so it can go
        /// through the same scaling initializer as the bundled faces.
        public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            guard FontLoader.hasManrope else { return systemFallback(size, weight, .default) }
            return .custom(FontLoader.manropeName(for: weight), size: size, relativeTo: .body)
        }

        public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            guard FontLoader.hasPlexMono else { return systemFallback(size, weight, .monospaced) }
            return .custom(FontLoader.plexMonoName(for: weight), size: size, relativeTo: .body)
        }

        /// The system face at the same size and weight, for when a bundled
        /// face did not register.
        private static func systemFallback(
            _ size: CGFloat, _ weight: Font.Weight, _ design: Font.Design
        ) -> Font {
            #if canImport(AppKit)
            let font = design == .monospaced
                ? NSFont.monospacedSystemFont(ofSize: size, weight: weight.nsWeight)
                : NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
            return .custom(font.fontName, size: size, relativeTo: .body)
            #else
            // UIKit's system faces cannot be asked for by name, so this path
            // gives up Dynamic Type scaling. It is a fallback for a build
            // that lost its fonts, not a layout anyone ships.
            return .system(size: size, weight: weight, design: design)
            #endif
        }

        // Named roles, so a screen never picks a raw size.
        public static var display: Font { sans(46, .heavy) }          // album title
        public static var immersiveTitle: Font { sans(38, .heavy) }
        public static var screenTitle: Font { sans(30, .heavy) }      // Artists / Albums
        public static var paneTitle: Font { sans(16, .bold) }         // now playing
        public static var rowTitle: Font { sans(14, .semibold) }      // artist name
        public static var trackTitle: Font { sans(13.5, .semibold) }
        public static var cardTitle: Font { sans(13, .bold) }
        public static var navItem: Font { sans(13, .semibold) }
        public static var body: Font { sans(13, .medium) }
        public static var caption: Font { sans(11.5, .medium) }
        public static var captionSmall: Font { sans(10.5, .medium) }

        /// Mono is the design's signal for anything machine-measured — times,
        /// sample rates, counts, section labels.
        public static var monoLabel: Font { mono(10, .medium) }
        public static var monoSmall: Font { mono(9.5, .medium) }
        public static var monoValue: Font { mono(11, .regular) }
        public static var monoTime: Font { mono(11.5, .regular) }

        /// Letter-spacing, which SwiftUI calls tracking.
        public enum Tracking {
            public static let display: CGFloat = -1.2      // -0.03em at 46px
            public static let screenTitle: CGFloat = -0.6  // -0.02em at 30px
            public static let label: CGFloat = 1.5         // 0.15em at 10px
            public static let wordmark: CGFloat = 2.1      // 0.16em at 13px
            public static let badge: CGFloat = 0.8
        }
    }

    // MARK: - Motion

    public enum Motion {
        /// The immersive artwork lift on hover.
        public static let artLift = Animation.timingCurve(0.22, 0.8, 0.28, 1, duration: 0.4)
        public static let controls = Animation.easeOut(duration: 0.22)
        /// Colour and wash changes as the pointer comes and goes. Long
        /// enough to read as a fade rather than a flicker, short enough that
        /// sweeping down a list never trails behind the pointer.
        public static let hover = Animation.easeOut(duration: 0.18)
        /// A cover rising under the pointer: a soft spring, no overshoot
        /// you would notice.
        public static let lift = Animation.spring(response: 0.34, dampingFraction: 0.82)
        /// A button giving under a click and springing back.
        public static let press = Animation.spring(response: 0.22, dampingFraction: 0.65)
    }
}

// MARK: - Font registration

/// Registers the bundled faces once, and reports whether they took. Keeping the
/// answer in one place means `Tokens.Typography` is the only caller that has to
/// think about the fallback.
///
/// Manrope ships from Google Fonts as a single variable file rather than one
/// file per weight. CoreText exposes its named instances — Manrope-Regular
/// through Manrope-ExtraBold — as ordinary font names once the file is
/// registered, so nothing above here has to know the difference.
public enum FontLoader {

    /// Where the resources actually are.
    ///
    /// Deliberately not `Bundle.module`: SwiftPM generates an accessor that
    /// looks only beside the executable or at the `.app` root, and calls
    /// `fatalError` when it finds nothing. Inside a hand-assembled bundle the
    /// resources live in `Contents/Resources`, which that accessor never
    /// checks — so the app died on launch before drawing a pixel. This
    /// searches the plausible locations and, finding none, lets the caller
    /// fall back to system fonts.
    static let resourceBundles: [Bundle] = {
        var found: [Bundle] = []
        // SwiftPM names a resource bundle `<package>_<target>`. Inside an
        // assembled `.app` (the Mac's `make app`, or Xcode's iOS build) it is
        // in the resources folder; under `swift run` and `swift test` it sits
        // beside the binary or the test bundle.
        let name = "Cadence_CadenceDesign.bundle"
        let marker = Bundle(for: BundleMarker.self)
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            marker.resourceURL?.appendingPathComponent(name),
            marker.bundleURL.deletingLastPathComponent().appendingPathComponent(name),
            Bundle.main.resourceURL,
            marker.resourceURL,
        ]
        for case let url? in candidates {
            guard let bundle = Bundle(url: url) else { continue }
            guard !found.contains(where: { $0.bundleURL == bundle.bundleURL }) else { continue }
            found.append(bundle)
        }
        return found
    }()

    /// Only exists to give `Bundle(for:)` a class in this module to locate.
    private final class BundleMarker {}

    /// Registers every font file found, then reports which families actually
    /// resolved. Scanning rather than naming expected files means swapping the
    /// variable font for statics, or adding an italic, needs no code change.
    private static let registered: (manrope: Bool, plex: Bool) = {
        for bundle in resourceBundles {
            for ext in ["ttf", "otf", "ttc"] {
                for url in bundle.urls(forResourcesWithExtension: ext,
                                       subdirectory: nil) ?? [] {
                    // An already-registered file reports an error; harmless,
                    // so the result is ignored and availability is settled by
                    // asking for the face below.
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
        }
        return (isAvailable("Manrope-Regular"), isAvailable("IBMPlexMono-Regular"))
    }()

    public static var hasManrope: Bool { registered.manrope }
    public static var hasPlexMono: Bool { registered.plex }

    public static func manropeName(for weight: Font.Weight) -> String {
        switch weight {
        case .heavy, .black: "Manrope-ExtraBold"
        case .bold: "Manrope-Bold"
        case .semibold: "Manrope-SemiBold"
        case .medium: "Manrope-Medium"
        default: "Manrope-Regular"
        }
    }

    public static func plexMonoName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black: "IBMPlexMono-Medium"
        default: "IBMPlexMono-Regular"
        }
    }

    /// Called at launch so registration failures surface once, at a moment we
    /// can log them, rather than lazily on first text draw.
    @discardableResult
    public static func warmUp() -> Bool { hasManrope && hasPlexMono }

    /// Every face the design asks for, and whether it resolved. Printed by
    /// `Cadence --fonts`.
    public static func report() -> [(name: String, available: Bool)] {
        _ = registered
        let weights: [Font.Weight] = [.regular, .medium, .semibold, .bold, .heavy]
        let names = weights.map(manropeName(for:))
            + [plexMonoName(for: .regular), plexMonoName(for: .medium)]
        return names.map { ($0, isAvailable($0)) }
    }

    private static func isAvailable(_ name: String) -> Bool {
        #if canImport(AppKit)
        NSFont(name: name, size: 12) != nil
        #else
        UIFont(name: name, size: 12) != nil
        #endif
    }
}

// MARK: - Weight bridging

#if canImport(AppKit)
extension Font.Weight {
    /// For handing a weight to an `NSFont` factory — the system-font fallback
    /// in `Tokens.Typography` needs the AppKit type to ask for a specific
    /// boldness.
    var nsWeight: NSFont.Weight {
        switch self {
        case .black: .black
        case .heavy: .heavy
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        case .light: .light
        case .thin: .thin
        case .ultraLight: .ultraLight
        default: .regular
        }
    }
}
#endif

// MARK: - Hex

extension Color {
    /// The design is written in hex; this keeps the token file readable
    /// against it.
    public init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
