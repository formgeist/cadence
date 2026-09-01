import SwiftUI
import CoreText
import AppKit

/// Every value in the interface comes from here. Views reference tokens, never
/// literals, so when the design shifts one file changes — see PLAN.md §6.
///
/// The values are lifted from `Cadence.dc.html`, the design canvas. Where the
/// mock and native macOS disagree, the comment says which won and why.
enum Tokens {

    // MARK: - Palette

    /// Dark only, as the design is. Should a light appearance ever be wanted,
    /// this is the one type that has to change.
    enum Palette {
        /// The window's own ground.
        static let surface = Color(hex: 0x0E0E11)
        /// Title bar.
        static let chrome = Color(hex: 0x131317)
        /// Sidebar and now-playing pane — a step darker than the content.
        static let panel = Color(hex: 0x101014)
        /// A grouped card sitting *on* the content surface — the Preferences
        /// sections. A step lighter than `surface`, so the group reads as
        /// raised rather than cut into the background.
        static let card = Color(hex: 0x141418)
        /// Behind the immersive view.
        static let immersiveTop = Color(hex: 0x171315)
        static let immersiveBottom = Color(hex: 0x08080A)

        static let accent = Color(hex: 0xE8483F)
        static let accentHover = Color(hex: 0xF4574E)
        static let accentDim = Color(hex: 0xE8483F).opacity(0.09)
        static let accentEdge = Color(hex: 0xE8483F).opacity(0.40)

        static let textPrimary = Color(hex: 0xF2F2F6)
        static let textSecondary = Color(hex: 0x9B9BA5)
        static let textTertiary = Color(hex: 0x6D6D77)
        /// Mono section labels — LIBRARY, UP NEXT, TITLE.
        static let textMuted = Color(hex: 0x55555F)
        static let textFaint = Color(hex: 0x4F4F58)

        static let border = Color(hex: 0x1E1E23)
        static let borderStrong = Color(hex: 0x2C2C34)
        static let separator = Color(hex: 0x1D1D23)

        /// Track and artist rows.
        static let rowHover = Color(hex: 0x16161B)
        /// The row that is playing.
        static let rowActive = Color(hex: 0x17171C)
        static let navHover = Color(hex: 0x1B1B21)
        static let navActive = Color(hex: 0x1E1E25)

        static let fieldBackground = Color(hex: 0x1B1B21)
        static let fieldBorder = Color(hex: 0x2B2B33)
        static let fieldFocusBackground = Color(hex: 0x1F1F26)
        static let fieldFocusBorder = Color(hex: 0x3D3D48)

        static let popover = Color(hex: 0x17171C)
        static let popoverBorder = Color(hex: 0x2B2B33)
        /// The row wash on a popover. Lighter than `rowHover`, which is a step
        /// *darker* than the content behind it and disappears entirely on the
        /// popover's own ground. Shared by the search results and the actions
        /// menu, so the two cannot drift.
        static let popoverHover = Color(hex: 0x1F1F26)

        static let trackGroove = Color(hex: 0x24242B)

        /// The two stripes of the placeholder artwork hatch.
        static let placeholderLight = Color(hex: 0x24242B)
        static let placeholderDark = Color(hex: 0x1B1B21)
        static let placeholderBorder = Color(hex: 0x2A2A32)
    }

    // MARK: - Space

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 26
        /// The horizontal inset every content screen shares.
        static let contentInset: CGFloat = 32
        static let albumInset: CGFloat = 40
        static let paneInset: CGFloat = 20
    }

    // MARK: - Radius

    enum Radius {
        static let thumb: CGFloat = 4
        static let control: CGFloat = 6
        static let row: CGFloat = 7
        static let card: CGFloat = 8
        static let popover: CGFloat = 10
        static let panel: CGFloat = 14
    }

    // MARK: - Layout

    enum Layout {
        static let sidebarWidth: CGFloat = 216
        static let nowPlayingWidth: CGFloat = 300
        static let titleBarHeight: CGFloat = 52
        /// Room for the real traffic lights. The mock draws its own; a native
        /// window with `.hiddenTitleBar` already has them, so this is reserved
        /// space rather than three painted circles.
        static let trafficLightInset: CGFloat = 78
        static let searchFieldMaxWidth: CGFloat = 480
        static let albumHeaderArt: CGFloat = 248
        static let artistHeaderArt: CGFloat = 156
        /// Narrower than an album card: an artist card carries a name and two
        /// counts, not a title that wraps.
        static let artistColumnWidth: CGFloat = 152
        /// The Recents grid has no zoom control, so its cards take one fixed
        /// width — a touch wider than the album grid's default so a mixed wall
        /// of covers and playlists reads calmly.
        static let recentColumnWidth: CGFloat = 184
        static let immersiveArt: CGFloat = 540
        /// Fixed regardless of hover, so the artwork above it never has to
        /// move to make room for the transport controls fading in.
        static let immersiveBandHeight: CGFloat = 176
        /// Preferences is a full page now, but its rows are a name, a caption
        /// and one control — a measure this wide keeps them readable rather
        /// than stretching the control halfway across the window.
        static let settingsContentWidth: CGFloat = 620
        static let minWindow = CGSize(width: 1_060, height: 660)
        static let defaultWindow = CGSize(width: 1_280, height: 820)
    }

    // MARK: - Type

    /// The design specifies Manrope and IBM Plex Mono. Both are registered from
    /// the app bundle at launch when the files are present; when they are not,
    /// every call falls back to the system face at the same size and weight, so
    /// the app runs either way and only the texture changes.
    enum Typography {
        static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            guard FontLoader.hasManrope else { return .system(size: size, weight: weight) }
            return .custom(FontLoader.manropeName(for: weight), fixedSize: size)
        }

        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            guard FontLoader.hasPlexMono else {
                return .system(size: size, weight: weight, design: .monospaced)
            }
            return .custom(FontLoader.plexMonoName(for: weight), fixedSize: size)
        }

        // Named roles, so a screen never picks a raw size.
        static var display: Font { sans(46, .heavy) }          // album title
        static var immersiveTitle: Font { sans(38, .heavy) }
        static var screenTitle: Font { sans(30, .heavy) }      // Artists / Albums
        static var paneTitle: Font { sans(16, .bold) }         // now playing
        static var rowTitle: Font { sans(14, .semibold) }      // artist name
        static var trackTitle: Font { sans(13.5, .semibold) }
        static var cardTitle: Font { sans(13, .bold) }
        static var navItem: Font { sans(13, .semibold) }
        static var body: Font { sans(13, .medium) }
        static var caption: Font { sans(11.5, .medium) }
        static var captionSmall: Font { sans(10.5, .medium) }

        /// Mono is the design's signal for anything machine-measured — times,
        /// sample rates, counts, section labels.
        static var monoLabel: Font { mono(10, .medium) }
        static var monoSmall: Font { mono(9.5, .medium) }
        static var monoValue: Font { mono(11, .regular) }
        static var monoTime: Font { mono(11.5, .regular) }

        /// Letter-spacing, which SwiftUI calls tracking.
        enum Tracking {
            static let display: CGFloat = -1.2      // -0.03em at 46px
            static let screenTitle: CGFloat = -0.6  // -0.02em at 30px
            static let label: CGFloat = 1.5         // 0.15em at 10px
            static let wordmark: CGFloat = 2.1      // 0.16em at 13px
            static let badge: CGFloat = 0.8
        }
    }

    // MARK: - Motion

    enum Motion {
        /// The immersive artwork lift on hover.
        static let artLift = Animation.timingCurve(0.22, 0.8, 0.28, 1, duration: 0.4)
        static let controls = Animation.easeOut(duration: 0.22)
        static let hover = Animation.easeOut(duration: 0.12)
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
enum FontLoader {

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
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Cadence_Cadence.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Cadence_Cadence.bundle"),
            Bundle.main.resourceURL,
            Bundle(for: BundleMarker.self).resourceURL,
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
        return (NSFont(name: "Manrope-Regular", size: 12) != nil,
                NSFont(name: "IBMPlexMono-Regular", size: 12) != nil)
    }()

    static var hasManrope: Bool { registered.manrope }
    static var hasPlexMono: Bool { registered.plex }

    static func manropeName(for weight: Font.Weight) -> String {
        switch weight {
        case .heavy, .black: "Manrope-ExtraBold"
        case .bold: "Manrope-Bold"
        case .semibold: "Manrope-SemiBold"
        case .medium: "Manrope-Medium"
        default: "Manrope-Regular"
        }
    }

    static func plexMonoName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black: "IBMPlexMono-Medium"
        default: "IBMPlexMono-Regular"
        }
    }

    /// Called at launch so registration failures surface once, at a moment we
    /// can log them, rather than lazily on first text draw.
    @discardableResult
    static func warmUp() -> Bool { hasManrope && hasPlexMono }

    /// Every face the design asks for, and whether it resolved. Printed by
    /// `Cadence --fonts`.
    static func report() -> [(name: String, available: Bool)] {
        _ = registered
        let weights: [Font.Weight] = [.regular, .medium, .semibold, .bold, .heavy]
        let names = weights.map(manropeName(for:))
            + [plexMonoName(for: .regular), plexMonoName(for: .medium)]
        return names.map { ($0, NSFont(name: $0, size: 12) != nil) }
    }
}

// MARK: - Hex

extension Color {
    /// The design is written in hex; this keeps the token file readable
    /// against it.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
