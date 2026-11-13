import SwiftUI
import CadenceDesign

extension Tokens {
    enum Layout {
        static let sidebarWidth: CGFloat = 216
        static let nowPlayingWidth: CGFloat = 340
        static let titleBarHeight: CGFloat = 52
        /// Room for the real traffic lights. The mock draws its own; a native
        /// window with `.hiddenTitleBar` already has them, so this is reserved
        /// space rather than three painted circles.
        static let trafficLightInset: CGFloat = 78
        static let searchFieldMaxWidth: CGFloat = 480
        static let albumHeaderArt: CGFloat = 248
        static let artistHeaderArt: CGFloat = 156
        /// Cover on each record of the artist page, where several share a screen.
        static let artistAlbumArt: CGFloat = 140
        /// Narrower than an album card: an artist card carries a name and two
        /// counts, not a title that wraps.
        static let artistColumnWidth: CGFloat = 152
        /// The Recents grid has no zoom control, so its cards take one fixed
        /// width — a touch wider than the album grid's default so a mixed wall
        /// of covers and playlists reads calmly.
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
        /// The search modal's card. Fixed rather than proportional to the
        /// window — a command palette reads as an object floating over the
        /// content, not a pane that resizes with it.
        static let searchModalWidth: CGFloat = 704
        static let searchModalMaxHeight: CGFloat = 624
        /// Distance from the window's top edge, clear of the title bar.
        static let searchModalTopInset: CGFloat = 96
        /// The card's fixed chrome — header, footer, and the two hairlines
        /// between them — used to fit the scrollable area to a short window
        /// alongside `searchModalTopInset`. Not measured live: header and
        /// footer are single-line rows at known padding, so this stays a
        /// constant rather than a `GeometryReader` round trip.
        static let searchModalChromeHeight: CGFloat = 110
    }

    // MARK: - Type
}
