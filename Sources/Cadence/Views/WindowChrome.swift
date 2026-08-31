import SwiftUI
import AppKit

/// Puts the app's own header where the window's title bar would be.
///
/// `.windowStyle(.hiddenTitleBar)` hides the title, but the content still
/// began *below* the title bar: the traffic lights sat alone in a band with
/// the back button and the search field stranded underneath — issue #15.
/// `.fullSizeContentView`, plus `RootView` ignoring the top safe area, is what
/// actually runs the content to the top of the window.
///
/// Nothing is drawn here. `TitleBarView` already reserves the lights' width.
@MainActor
enum WindowChrome {

    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // A restored window would skip straight to whatever frame macOS
        // cached at last quit — including a loaded library — rather than
        // ever showing the real, live loading state. Nothing about this app
        // needs that continuity, so it's off rather than left to chance.
        window.isRestorable = false
        installTallTitleBar(on: window)
    }

    /// AppKit centres the traffic lights in a standard ~28pt title bar, so
    /// against Cadence's 52pt header the hand-moved buttons this used to ship
    /// never quite matched other Mac apps — the cluster sat a touch high, and
    /// the resize / full-screen re-layout hooks didn't always keep up.
    ///
    /// An *empty* `NSToolbar` in the `.unified` style raises the title-bar
    /// band to the standard unified height — ~52pt, which `titleBarHeight` is
    /// set to match — and AppKit then keeps the lights centred in it across
    /// resize and full screen with no per-button math. That unified height is
    /// fixed: the header can't grow past it without going back to positioning
    /// the buttons by hand. `titlebarAppearsTransparent` keeps the toolbar
    /// from drawing any material over the header behind it (the search field,
    /// issue #15's fix) — the regression the first unified-toolbar attempt
    /// shipped was a *non*-transparent bar.
    static func installTallTitleBar(on window: NSWindow) {
        let toolbar: NSToolbar
        if let existing = window.toolbar {
            toolbar = existing
        } else {
            toolbar = NSToolbar(identifier: "CadenceChrome")
            toolbar.delegate = sharedToolbarDelegate
            window.toolbar = toolbar
        }
        toolbar.showsBaselineSeparator = false
        window.toolbarStyle = .unified
    }

    /// An empty toolbar still needs a delegate to be well-formed. Retained for
    /// the process lifetime — one window, one toolbar.
    private static let sharedToolbarDelegate = EmptyToolbarDelegate()

    private final class EmptyToolbarDelegate: NSObject, NSToolbarDelegate {
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
        func toolbar(_ toolbar: NSToolbar,
                     itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
    }
}

/// Applies the chrome to whichever window this view lands in. A representable
/// rather than something in `AppDelegate`, so a second window gets it too.
///
/// The unified toolbar keeps the traffic lights placed correctly across
/// resize and full-screen on its own, so unlike the hand-positioned version
/// this needs no notification observers — just one application once the view
/// has a window.
struct WindowChromeConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window until it is in the hierarchy.
        Task { @MainActor in
            guard let window = view.window else { return }
            WindowChrome.apply(to: window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        WindowChrome.apply(to: window)
    }
}
