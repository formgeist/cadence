import SwiftUI
import AppKit
import CadenceCore
import CadenceLibrary
import ApplicationServices

/// `Cadence --a11y` — walks the real accessibility tree and prints it.
///
/// Accessibility modifiers are easy to write and easy to get wrong: a label on
/// the wrong node, a decorative image still exposed, a control with no name at
/// all. Reading the tree back is the only way to know what VoiceOver would
/// actually say, short of turning VoiceOver on.
@MainActor
enum A11yHarness {

    static func parse(_ arguments: [String]) -> Bool {
        arguments.contains("--a11y")
    }

    static func run() async throws -> Int32 {
        let container = AppContainer(mode: .preview)
        await container.model.load()
        container.playback.play(PreviewData.slowHours[2], in: PreviewData.slowHours)
        container.playback.seek(to: 88)

        var unlabelled = 0

        for screen in Screen.allCases {
            // The mock clock keeps running between screens; without this the
            // transport disappears and its labels go unchecked.
            if container.playback.currentTrack == nil {
                container.playback.play(PreviewData.slowHours[2], in: PreviewData.slowHours)
            }
            container.playback.seek(to: 88)
            screen.configure(container)

            let view = RootView()
                .environment(container.model)
                .environment(container.playback)
                .environment(container.importer)
                .environment(container.artworkLoader)
                .environment(\.isSilentPlayback, container.isSilentPlayback)
                .preferredColorScheme(.dark)

            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: Tokens.Layout.defaultWindow),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            window.orderFrontRegardless()

            for _ in 0..<25 { try await Task.sleep(for: .milliseconds(16)) }

            print("\n── \(screen.title) ──")
            var elements: [Element] = []
            // The AX tree is built on demand for an assistive client, so it is
            // queried through the accessibility API rather than read off the
            // views directly.
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            collectAX(app, into: &elements)
            if elements.isEmpty {
                collect(window.contentView, into: &elements)
            }

            for element in elements {
                let name = element.label.isEmpty ? "⟨no label⟩" : "\"\(element.label)\""
                let value = element.value.map { " = \"\($0)\"" } ?? ""
                let flag = element.isProblem ? "  ✗" : ""
                if element.isProblem { unlabelled += 1 }
                print("  \(element.role.padding(toLength: 12, withPad: " ", startingAt: 0)) \(name)\(value)\(flag)")
            }
            window.orderOut(nil)
        }

        print("\n\(unlabelled) control(s) with nothing to announce")
        return unlabelled == 0 ? 0 : 1
    }

    private enum Screen: CaseIterable {
        case artists, album, immersive

        var title: String {
            switch self {
            case .artists: "Library — Artists"
            case .album: "Album detail"
            case .immersive: "Immersive"
            }
        }

        @MainActor
        func configure(_ container: AppContainer) {
            switch self {
            case .artists:
                container.model.isImmersive = false
                container.model.show(.library)
                container.model.tab = .artists
            case .album:
                container.model.isImmersive = false
                if let album = container.model.albums.first(where: {
                    $0.title == "Sound of the Slow Hours" && $0.year == 2023
                }) {
                    container.model.show(.album(album.key))
                }
            case .immersive:
                container.model.isImmersive = true
            }
        }
    }

    private struct Element {
        var role: String
        var label: String
        var value: String?

        /// Static text is its own label — VoiceOver reads the value, and an
        /// empty `AXDescription` on it is normal rather than a defect. What
        /// matters is a *control* with nothing to announce.
        var isProblem: Bool {
            guard label.isEmpty else { return false }
            let interactive = ["Button", "CheckBox", "Slider", "MenuButton",
                               "TextField", "PopUpButton", "Image", "ValueIndicator"]
            guard interactive.contains(role) else { return false }
            return (value ?? "").isEmpty
        }
    }

    /// Reads the tree the way an assistive client does.
    private static func collectAX(_ element: AXUIElement, into found: inout [Element],
                                  depth: Int = 0) {
        guard depth < 40 else { return }

        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString,
                                                &value) == .success else { return nil }
            return value as? String
        }

        let role = (string(kAXRoleAttribute) ?? "AXUnknown")
            .replacingOccurrences(of: "AX", with: "")
        let label = string(kAXDescriptionAttribute) ?? string(kAXTitleAttribute) ?? ""
        let value = string(kAXValueAttribute)

        // The menu bar is the system's, not this app's, and walking it buries
        // the app's own elements under a hundred menu items.
        if role == "MenuBar" { return }
        // A scroll bar's arrows and knob are AppKit's own parts. They are not
        // stops for VoiceOver and they are not this app's to label.
        if role == "ScrollBar" { return }

        let containers = ["Group", "ScrollArea", "ScrollBar", "Unknown", "Window",
                          "SplitGroup", "Outline", "List", "Application", "Row",
                          "Cell", "Column", "OpaqueProviderMarker"]
        // A container is only noise when it is anonymous. One carrying a label
        // is a real stop — SwiftUI exposes an adjustable element built from
        // shapes as a labelled group, and filtering by role alone hid every
        // slider in the app.
        if !containers.contains(role) || !label.isEmpty {
            found.append(Element(role: role, label: label,
                                 value: label == value ? nil : value))
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { collectAX(child, into: &found, depth: depth + 1) }
    }

    /// Walks the *accessibility* tree, not the view tree.
    ///
    /// SwiftUI's accessibility elements are not NSViews — they are exposed
    /// through `accessibilityChildren()` on the hosting view. Recursing through
    /// `subviews` finds only AppKit's own scroll views and groups, which is how
    /// a first attempt at this reported thirty unlabelled elements and none of
    /// the real ones.
    private static func collect(_ node: Any?, into found: inout [Element], depth: Int = 0) {
        guard depth < 40, let element = node as? NSAccessibilityProtocol else { return }

        let role = (element.accessibilityRole()?.rawValue ?? "AXUnknown")
            .replacingOccurrences(of: "AX", with: "")
        let label = element.accessibilityLabel() ?? element.accessibilityTitle() ?? ""
        let value = element.accessibilityValue() as? String

        // Containers carry no name of their own and are not stops.
        let isStop = !["Group", "ScrollArea", "ScrollBar", "Unknown",
                       "Window", "SplitGroup", "Outline", "List"].contains(role)

        if isStop {
            found.append(Element(role: role, label: label,
                                 value: label == value ? nil : value))
        }

        for child in element.accessibilityChildren() ?? [] {
            collect(child, into: &found, depth: depth + 1)
        }
    }
}
