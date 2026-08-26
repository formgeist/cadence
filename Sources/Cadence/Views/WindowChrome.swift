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
        centreTrafficLights(in: window)
    }

    /// AppKit centres the lights in a 28pt title bar, so against a 52pt header
    /// they float ten points above the search field they share a row with.
    ///
    /// A unified toolbar would centre them natively. It also paints its own
    /// background over the title bar area, which hid the search field
    /// completely — the first attempt at this shipped that way for one build.
    /// Moving three buttons is both smaller and visible in what it does.
    static func centreTrafficLights(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let container = buttons.first?.superview else { return }
        for button in buttons {
            button.frame.origin.y = container.bounds.height
                - Tokens.Layout.titleBarHeight / 2 - button.bounds.height / 2
        }
    }
}

/// Applies the chrome to whichever window this view lands in. A representable
/// rather than something in `AppDelegate`, so a second window gets it too.
struct WindowChromeConfigurator: NSViewRepresentable {

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window until it is in the hierarchy.
        Task { @MainActor in
            guard let window = view.window else { return }
            WindowChrome.apply(to: window)
            context.coordinator.observe(window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        WindowChrome.apply(to: window)
        context.coordinator.observe(window)
    }

    /// AppKit lays the traffic lights out again whenever the window resizes or
    /// leaves full screen, putting them back at the top. Without this they
    /// re-centre only on the next SwiftUI update, which for a window nobody is
    /// interacting with may not come.
    @MainActor
    final class Coordinator: NSObject {
        private weak var observed: NSWindow?

        func observe(_ window: NSWindow) {
            guard observed !== window else { return }
            NotificationCenter.default.removeObserver(self)
            observed = window
            for name in [NSWindow.didResizeNotification,
                         NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowChanged),
                    name: name, object: window)
            }
        }

        @objc private func windowChanged(_ note: Notification) {
            guard let window = note.object as? NSWindow else { return }
            WindowChrome.centreTrafficLights(in: window)
        }
    }
}
