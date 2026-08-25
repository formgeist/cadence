import SwiftUI
import AppKit
import Observation

// MARK: - Content

/// One firing row in a menu.
@MainActor
struct MenuAction {
    var title: String
    /// Every row carries one. The point of the redesign is that the menu
    /// speaks the same symbol-led language as the Play pill and the sidebar,
    /// so a row without a glyph is a row that got missed.
    var systemImage: String
    /// Display only — the binding itself lives wherever the action does. Shown
    /// in mono at the trailing edge, the face the app already uses for every
    /// machine-measured fact.
    var shortcut: String?
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    var handler: () -> Void
}

/// What a Cadence menu is made of.
@MainActor
struct MenuItem: Identifiable {
    enum Kind {
        case action(MenuAction)
        case separator
        /// One level deep, which is all the app has ever needed: the
        /// destination list behind "Add to Playlist".
        case submenu(title: String, systemImage: String, items: [MenuItem])
        /// A row that shows whether it is the live answer. Pickers only.
        case choice(title: String, isOn: Bool, handler: () -> Void)
        /// Content that isn't a verb — the album grid's zoom slider, so far.
        /// Manages its own interaction, so it skips the hover wash, the
        /// keyboard focus ring and `onFire` entirely; see `isFocusable`.
        case custom(AnyView)
    }

    let id = UUID()
    var kind: Kind

    static func action(_ title: String,
                       _ systemImage: String,
                       shortcut: String? = nil,
                       destructive: Bool = false,
                       enabled: Bool = true,
                       _ handler: @escaping () -> Void) -> MenuItem {
        MenuItem(kind: .action(MenuAction(title: title,
                                          systemImage: systemImage,
                                          shortcut: shortcut,
                                          isDestructive: destructive,
                                          isEnabled: enabled,
                                          handler: handler)))
    }

    /// Computed rather than stored: every `MenuItem` mints an id on init, and a
    /// shared static one would hand two separators in the same menu the same
    /// identity — which `ForEach` resolves by drawing one of them.
    static var separator: MenuItem { MenuItem(kind: .separator) }

    static func submenu(_ title: String,
                        _ systemImage: String,
                        items: [MenuItem]) -> MenuItem {
        MenuItem(kind: .submenu(title: title, systemImage: systemImage, items: items))
    }

    static func choice(_ title: String,
                       isOn: Bool,
                       _ handler: @escaping () -> Void) -> MenuItem {
        MenuItem(kind: .choice(title: title, isOn: isOn, handler: handler))
    }

    static func custom<Content: View>(@ViewBuilder _ content: () -> Content) -> MenuItem {
        MenuItem(kind: .custom(AnyView(content())))
    }

    /// Separators are not stops on the way down the menu, and neither is a
    /// row the model has switched off — nor custom content, which has no
    /// single "fire" and handles its own input.
    var isFocusable: Bool {
        switch kind {
        case .separator, .custom: false
        case .action(let action): action.isEnabled
        case .submenu, .choice: true
        }
    }
}

// MARK: - Metrics

/// The menu's geometry, in one place. `MenuPresenter` needs the same numbers
/// to size and place a panel that the surface needs to draw it, so they cannot
/// live inside the view.
enum MenuMetrics {
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 1
    /// 5 above, the hairline, 5 below.
    static let separatorHeight: CGFloat = 11
    static let surfacePadding: CGFloat = 6
    static let minWidth: CGFloat = 216
    static let maxWidth: CGFloat = 340
    /// Between the trigger's bottom edge and the menu's top edge.
    static let anchorGap: CGFloat = 8
    /// Between a submenu and the menu that opened it.
    static let submenuGap: CGFloat = 4
    /// How close to the screen edge a menu is allowed to sit.
    static let screenInset: CGFloat = 8
    static let iconBox: CGFloat = 16
    static let iconGap: CGFloat = 10
    static let rowInset: CGFloat = 8
}

// MARK: - Level state

/// What one open menu knows about itself. A reference type because the panel,
/// the presenter and the SwiftUI surface all mutate the same focus.
@MainActor
@Observable
final class MenuLevelState {
    /// The row under the pointer, or the one the arrow keys have reached.
    var focused: UUID?
    /// Set when the focus came from the keyboard, so the row can wear an
    /// accent edge the pointer never draws.
    var focusFromKeyboard = false
    /// The submenu row that is currently expanded, if any.
    var openSubmenu: UUID?
    /// Row rectangles in the surface's own coordinate space, reported back by
    /// the rows themselves so a submenu can be hung off one.
    var rowFrames: [UUID: CGRect] = [:]
}

// MARK: - Surface

/// The menu itself: the popover surface every other Cadence popover already
/// uses, with a list of verbs on it instead of a list of albums.
struct MenuSurface: View {
    var items: [MenuItem]
    var state: MenuLevelState
    var onFire: (MenuItem) -> Void
    var onHoverSubmenu: (MenuItem) -> Void

    private static let space = "cadence.menu.surface"

    var body: some View {
        VStack(alignment: .leading, spacing: MenuMetrics.rowSpacing) {
            ForEach(items) { item in
                row(for: item)
            }
        }
        .padding(MenuMetrics.surfacePadding)
        .frame(minWidth: MenuMetrics.minWidth,
               maxWidth: MenuMetrics.maxWidth,
               alignment: .leading)
        .fixedSize()
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .fill(Tokens.Palette.popover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .strokeBorder(Tokens.Palette.popoverBorder, lineWidth: 1)
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(MenuRowFrameKey.self) { frames in
            // Nonisolated in Swift 6; the state it feeds is main-actor bound.
            MainActor.assumeIsolated { state.rowFrames = frames }
        }
    }

    @ViewBuilder
    private func row(for item: MenuItem) -> some View {
        switch item.kind {
        case .separator:
            Rectangle()
                .fill(Tokens.Palette.separator)
                .frame(height: 1)
                .padding(.horizontal, MenuMetrics.surfacePadding)
                .frame(height: MenuMetrics.separatorHeight)
                .accessibilityHidden(true)

        case .action(let action):
            MenuRow(id: item.id,
                    title: action.title,
                    systemImage: action.systemImage,
                    shortcut: action.shortcut,
                    isDestructive: action.isDestructive,
                    isEnabled: action.isEnabled,
                    hasSubmenu: false,
                    state: state,
                    onFire: { onFire(item) },
                    onHover: { _ in state.openSubmenu = nil })

        case .submenu(let title, let systemImage, _):
            MenuRow(id: item.id,
                    title: title,
                    systemImage: systemImage,
                    shortcut: nil,
                    isDestructive: false,
                    isEnabled: true,
                    hasSubmenu: true,
                    state: state,
                    onFire: { onHoverSubmenu(item) },
                    onHover: { inside in if inside { onHoverSubmenu(item) } })

        case .choice(let title, let isOn, _):
            MenuRow(id: item.id,
                    title: title,
                    // The tick sits in the same 16pt gutter the symbols use, so
                    // ticked and unticked labels stay on one baseline.
                    systemImage: isOn ? "checkmark" : nil,
                    shortcut: nil,
                    isDestructive: false,
                    isEnabled: true,
                    hasSubmenu: false,
                    isChecked: isOn,
                    state: state,
                    onFire: { onFire(item) },
                    onHover: { _ in state.openSubmenu = nil })

        case .custom(let content):
            // No hover/submenu wiring: nothing here opens a submenu, and a
            // drag gesture underneath (the zoom slider) should not have
            // anything else in this view competing for the same pointer.
            content
                .padding(.horizontal, MenuMetrics.rowInset)
                .frame(height: MenuMetrics.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Row frames, gathered so a submenu knows where to hang.
private struct MenuRowFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct MenuRow: View {
    var id: UUID
    var title: String
    var systemImage: String?
    var shortcut: String?
    var isDestructive: Bool
    var isEnabled: Bool
    var hasSubmenu: Bool
    var isChecked: Bool = false
    var state: MenuLevelState
    var onFire: () -> Void
    var onHover: (Bool) -> Void

    private var isFocused: Bool { state.focused == id }
    /// Only the keyboard draws the edge; the pointer gets the wash alone.
    private var showsKeyboardEdge: Bool { isFocused && state.focusFromKeyboard }

    private var labelColor: Color {
        if isDestructive {
            return isFocused ? Tokens.Palette.accentHover : Tokens.Palette.accent
        }
        return isFocused ? Tokens.Palette.textPrimary : Color(hex: 0xDCDCE3)
    }

    private var glyphColor: Color {
        if isChecked { return Tokens.Palette.accent }
        if isDestructive {
            return isFocused ? Tokens.Palette.accentHover : Tokens.Palette.accent
        }
        return isFocused ? Color(hex: 0xC9C9D2) : Tokens.Palette.textTertiary
    }

    private var washColor: Color {
        guard isFocused else { return .clear }
        return isDestructive ? Tokens.Palette.accentDim : Tokens.Palette.popoverHover
    }

    var body: some View {
        HStack(spacing: MenuMetrics.iconGap) {
            // Always present, even when there is no glyph: an unticked picker
            // row still has to line its label up with the ticked one.
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: isChecked ? 10 : 11, weight: .semibold))
                        .foregroundStyle(glyphColor)
                }
            }
            .frame(width: MenuMetrics.iconBox, height: MenuMetrics.iconBox)

            Text(title)
                .font(Tokens.Typography.sans(12.5, .semibold))
                .foregroundStyle(labelColor)
                .lineLimit(1)

            Spacer(minLength: MenuMetrics.iconGap * 2)

            if let shortcut {
                Text(shortcut)
                    .font(Tokens.Typography.mono(10))
                    .tracking(0.6)
                    .foregroundStyle(isFocused
                                     ? Tokens.Palette.textTertiary
                                     : Tokens.Palette.textFaint)
            }

            if hasSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isFocused
                                     ? Tokens.Palette.textSecondary
                                     : Tokens.Palette.textFaint)
            }
        }
        .padding(.horizontal, MenuMetrics.rowInset)
        .frame(height: MenuMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .fill(washColor)
        }
        .overlay {
            if showsKeyboardEdge {
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(Tokens.Palette.accentEdge, lineWidth: 1)
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MenuRowFrameKey.self,
                    value: [id: geometry.frame(in: .named("cadence.menu.surface"))])
            }
        }
        .onHover { inside in
            guard isEnabled else { return }
            if inside {
                state.focused = id
                state.focusFromKeyboard = false
            } else if state.focused == id {
                state.focused = nil
            }
            onHover(inside)
        }
        .onTapGesture {
            guard isEnabled else { return }
            onFire()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isChecked ? "Selected" : "")
        .accessibilityHint(hasSubmenu ? "Opens a submenu" : "")
    }
}

// MARK: - Panel

/// The menu's window.
///
/// Deliberately not an `NSMenu`: its background is drawn by AppKit and there
/// is no way to reach it, which is the whole of issue #23. Deliberately not a
/// SwiftUI `.popover` either — that is an `NSPopover`, which insists on its
/// own material and draws an arrow no API removes. A borderless child panel is
/// what is left, and it is what a menu actually is.
final class MenuPanel: NSPanel {
    /// A borderless window is not key-eligible by default, and without the
    /// keyboard there is no arrow-key traversal to inherit from the NSMenu
    /// this replaces.
    override var canBecomeKey: Bool { true }
}

/// A real `NSMenu`'s tracking loop is a special case AppKit itself owns, so a
/// click on one of its items always just works. This panel is an ordinary
/// window standing in for that, and an ordinary window's first click — even
/// one it was just handed `makeKey()` for a moment earlier — is eaten purely
/// to bring it forward unless the view under the pointer opts out by
/// overriding this. Without it, the row a right-click lands on needs a
/// second, separate click before its tap gesture ever sees the first one.
private final class MenuHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Presenter

/// Owns every open menu. There is only ever one stack of them on screen, the
/// same way there is only ever one `NSMenu` tracking, so this is a singleton
/// rather than something threaded through the environment — the harnesses that
/// host a view tree without one would otherwise each need to know about it.
@MainActor
@Observable
final class MenuPresenter {
    static let shared = MenuPresenter()
    private init() {}

    /// Read by the Playback command menu. Bare Space is Play/Pause, and a menu
    /// key equivalent is dispatched before any window sees the event — the same
    /// trap `TextEntryMonitor` exists for. A disabled item does not claim its
    /// key equivalent, so the keystroke reaches the menu instead of the
    /// transport.
    var isPresenting: Bool { !levels.isEmpty }

    @ObservationIgnored private var levels: [Level] = []
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var onDismiss: (() -> Void)?

    private final class Level {
        let panel: MenuPanel
        let state: MenuLevelState
        let items: [MenuItem]

        init(panel: MenuPanel, state: MenuLevelState, items: [MenuItem]) {
            self.panel = panel
            self.state = state
            self.items = items
        }
    }

    // MARK: Presenting

    /// Opens `items` under `anchor`, a rectangle in screen coordinates —
    /// usually the trigger button's.
    func present(_ items: [MenuItem],
                 from anchor: CGRect,
                 gap: CGFloat = MenuMetrics.anchorGap,
                 in parent: NSWindow?,
                 onDismiss: @escaping () -> Void) {
        dismiss()
        self.onDismiss = onDismiss

        let level = makeLevel(items)
        place(level.panel, below: anchor, gap: gap)
        show(level, in: parent)
        levels = [level]
        startMonitoring(parent: parent)
    }

    /// Opens `items` at a point in screen coordinates — where a right-click
    /// landed. A cursor has no rectangle to clear, so unlike a button anchor
    /// this hangs straight off the point with no gap.
    func present(_ items: [MenuItem],
                 at point: CGPoint,
                 in parent: NSWindow?,
                 onDismiss: @escaping () -> Void = {}) {
        present(items,
                from: CGRect(origin: point, size: .zero),
                gap: 0,
                in: parent,
                onDismiss: onDismiss)
    }

    /// Closes everything and tells the trigger it is no longer lit.
    func dismiss() {
        guard !levels.isEmpty else { return }
        for level in levels { close(level) }
        levels = []
        stopMonitoring()
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    // MARK: Levels

    private func makeLevel(_ items: [MenuItem]) -> Level {
        let state = MenuLevelState()
        let panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit derives the shadow from the window's own alpha, so the rounded
        // surface gets a shadow that follows its corners. Drawing the design's
        // shadow in SwiftUI instead would need a transparent margin around the
        // menu, and that margin would swallow the clicks meant to dismiss it.
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        panel.isMovable = false
        panel.setAccessibilityRole(.menu)

        let level = Level(panel: panel, state: state, items: items)
        let surface = MenuSurface(
            items: items,
            state: state,
            onFire: { [weak self] item in self?.fire(item) },
            onHoverSubmenu: { [weak self] item in self?.openSubmenu(item, from: level) }
        )

        let hosting = MenuHostingView(rootView: surface)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return level
    }

    private func show(_ level: Level, in parent: NSWindow?) {
        parent?.addChildWindow(level.panel, ordered: .above)
        level.panel.orderFrontRegardless()
        level.panel.makeKey()
        level.panel.invalidateShadow()
    }

    private func close(_ level: Level) {
        level.panel.parent?.removeChildWindow(level.panel)
        level.panel.orderOut(nil)
        level.panel.contentView = nil
    }

    private func fire(_ item: MenuItem) {
        let handler: (() -> Void)? = switch item.kind {
        case .action(let action): action.isEnabled ? action.handler : nil
        case .choice(_, _, let handler): handler
        case .separator, .submenu, .custom: nil
        }
        guard let handler else { return }
        // Dismissed first so the menu is gone before a sheet or an alert the
        // action opens tries to take the keyboard from it.
        dismiss()
        // A beat later, not inline with it: `dismiss()` tears down the
        // panel's own key window synchronously, and a handler that hands
        // focus straight to something else — `NSWorkspace` activating
        // Finder, a `.sheet` taking the keyboard — can race that teardown
        // and silently do nothing, needing a second click to actually show
        // anything. Letting the teardown finish its run-loop turn first is
        // what a Cocoa app gets for free from a real `NSMenu`, which this
        // panel otherwise stands in for.
        Task { @MainActor in handler() }
    }

    // MARK: Submenus

    private func openSubmenu(_ item: MenuItem, from level: Level) {
        guard case .submenu(_, _, let items) = item.kind else { return }
        guard level.state.openSubmenu != item.id else { return }

        // Anything already open below this level goes first: moving from one
        // submenu row to another should not leave two flyouts on screen.
        while levels.count > depth(of: level) + 1, let last = levels.last {
            close(last)
            levels.removeLast()
        }
        level.state.openSubmenu = item.id
        // The parent row keeps its wash — it is still where you came from —
        // but hands the accent edge down to the flyout. Two ringed rows read
        // as two cursors.
        level.state.focusFromKeyboard = false

        guard let rowFrame = level.state.rowFrames[item.id] else { return }
        let child = makeLevel(items)
        place(child.panel, besideRow: rowFrame, of: level.panel)
        show(child, in: level.panel)
        levels.append(child)
    }

    private func depth(of level: Level) -> Int {
        levels.firstIndex { $0 === level } ?? 0
    }

    // MARK: Placement

    private func place(_ panel: NSPanel, below anchor: CGRect, gap: CGFloat) {
        let size = panel.frame.size
        let visible = screen(containing: anchor).visibleFrame
        var x = anchor.minX
        // AppKit counts up from the bottom, so "below the trigger" is a
        // smaller y than the trigger's own.
        var y = anchor.minY - gap - size.height

        if y < visible.minY + MenuMetrics.screenInset {
            // No room underneath — flip above the trigger rather than letting
            // the menu run off the bottom of the screen.
            let above = anchor.maxY + gap
            if above + size.height <= visible.maxY - MenuMetrics.screenInset {
                y = above
            } else {
                y = visible.minY + MenuMetrics.screenInset
            }
        }
        x = min(x, visible.maxX - MenuMetrics.screenInset - size.width)
        x = max(x, visible.minX + MenuMetrics.screenInset)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func place(_ panel: NSPanel, besideRow row: CGRect, of parent: NSWindow) {
        let size = panel.frame.size
        let parentFrame = parent.frame
        let visible = screen(containing: parentFrame).visibleFrame

        // `row` arrives in the surface's own coordinates — origin top left, y
        // growing downwards — so its top edge is the parent's top edge less
        // the row's offset into it.
        let rowTop = parentFrame.maxY - row.minY
        var y = rowTop + MenuMetrics.surfacePadding - size.height
        var x = parentFrame.maxX + MenuMetrics.submenuGap

        if x + size.width > visible.maxX - MenuMetrics.screenInset {
            x = parentFrame.minX - MenuMetrics.submenuGap - size.width
        }
        x = max(x, visible.minX + MenuMetrics.screenInset)
        y = max(y, visible.minY + MenuMetrics.screenInset)
        y = min(y, visible.maxY - MenuMetrics.screenInset - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screen(containing rect: CGRect) -> NSScreen {
        // `intersects` is false for an empty rectangle, and a right-click
        // anchor is exactly that — a point. Fall through to containment so a
        // context menu on a second display is not placed on the first.
        NSScreen.screens.first { $0.frame.intersects(rect) }
            ?? NSScreen.screens.first { $0.frame.contains(rect.origin) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: Dismissal and keys

    private func startMonitoring(parent: NSWindow?) {
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            // A click inside any open level is the menu's own business.
            if let window = event.window, self.levels.contains(where: { $0.panel === window }) {
                return event
            }
            self.dismiss()
            // Swallowed: the click that closes a menu should not also press
            // whatever happened to be underneath it, which is how every other
            // menu on the system behaves.
            return nil
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.levels.isEmpty else { return event }
            return self.handle(event) ? nil : event
        }

        if let parent {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: parent,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // The panel taking the keyboard from its own parent is the
                    // expected case, not a reason to close.
                    guard let self, let key = NSApp.keyWindow else { return }
                    guard !self.levels.contains(where: { $0.panel === key }) else { return }
                    self.dismiss()
                }
            }
        }
    }

    private func stopMonitoring() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        clickMonitor = nil
        keyMonitor = nil
        resignObserver = nil
    }

    /// Everything `NSMenu` did for free and a panel has to be told. Returns
    /// whether the keystroke was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let level = levels.last else { return false }

        // A contextual menu's key equivalents are live only while it is open —
        // which is exactly what the ⌫ beside Delete promises, and the reason
        // the hint is honest without a global binding existing.
        if let shortcut = shortcutMatch(event, in: level) {
            fire(shortcut)
            return true
        }

        switch Int(event.keyCode) {
        case 53:                                  // Escape
            if levels.count > 1 { closeTopLevel() } else { dismiss() }
            return true
        case 125:                                 // Down
            move(in: level, by: 1)
            return true
        case 126:                                 // Up
            move(in: level, by: -1)
            return true
        case 124:                                 // Right — into a submenu
            if let focused = focusedItem(in: level),
               case .submenu = focused.kind {
                openSubmenu(focused, from: level)
                if let child = levels.last, child !== level { move(in: child, by: 1) }
            }
            return true
        case 123:                                 // Left — back out of one
            if levels.count > 1 { closeTopLevel() }
            return true
        case 36, 76:                              // Return, Enter
            if let focused = focusedItem(in: level) {
                if case .submenu = focused.kind {
                    openSubmenu(focused, from: level)
                    if let child = levels.last, child !== level { move(in: child, by: 1) }
                } else {
                    fire(focused)
                }
            }
            return true
        default:
            // Swallowed wholesale. An open menu owns the keyboard: without
            // this, bare Space would reach the Playback command and toggle
            // the transport from behind the menu.
            return true
        }
    }

    private func closeTopLevel() {
        guard levels.count > 1, let top = levels.last else { return }
        close(top)
        levels.removeLast()
        levels.last?.state.openSubmenu = nil
    }

    private func focusedItem(in level: Level) -> MenuItem? {
        level.items.first { $0.id == level.state.focused }
    }

    /// The row whose displayed shortcut this keystroke is, if any. Unmodified
    /// keys only: ⌫ is Delete, ⌥⌫ is not.
    private func shortcutMatch(_ event: NSEvent, in level: Level) -> MenuItem? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.subtracting(.function).isEmpty else { return nil }

        let pressed: String? = switch Int(event.keyCode) {
        case 51: "⌫"
        default: nil
        }
        guard let pressed else { return nil }

        return level.items.first { item in
            guard case .action(let action) = item.kind else { return false }
            return action.isEnabled && action.shortcut == pressed
        }
    }

    private func move(in level: Level, by step: Int) {
        let stops = level.items.filter(\.isFocusable)
        guard !stops.isEmpty else { return }

        let next: MenuItem
        if let current = level.state.focused,
           let index = stops.firstIndex(where: { $0.id == current }) {
            // Wraps, as a real menu does.
            next = stops[(index + step + stops.count) % stops.count]
        } else {
            next = step > 0 ? stops[0] : stops[stops.count - 1]
        }
        level.state.focused = next.id
        level.state.focusFromKeyboard = true
        level.state.openSubmenu = nil

        while levels.count > depth(of: level) + 1, let last = levels.last {
            close(last)
            levels.removeLast()
        }
    }
}

// MARK: - Trigger

/// Reports where its view is on screen, so a menu can be hung off it from a
/// window that is not this one.
///
/// A `GeometryReader` cannot answer this: it measures inside the window, and a
/// panel is placed in screen coordinates.
@MainActor
final class ScreenRectProbe {
    fileprivate weak var view: NSView?

    /// The probed view's frame in screen coordinates, or `.zero` before it has
    /// been placed in a window — which is what the snapshot and accessibility
    /// harnesses see.
    var rect: CGRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    var window: NSWindow? { view?.window }
}

private struct ScreenRectReader: NSViewRepresentable {
    var probe: ScreenRectProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        probe.view = nsView
    }
}

/// Hangs a Cadence menu off whatever draws the trigger.
///
/// `items` is a closure rather than an array because a menu's contents depend
/// on state that changes while the screen is open — a playlist that has just
/// gained its first track has a Play row that works now.
///
/// The label is handed `isOpen` and the toggle rather than being wrapped in a
/// `Button` here, so a `CapsuleButton` can be used whole instead of being
/// nested inside another button.
struct MenuAnchor<Label: View>: View {
    var items: () -> [MenuItem]
    @ViewBuilder var label: (Bool, @escaping () -> Void) -> Label

    @State private var isOpen = false
    @State private var probe = ScreenRectProbe()

    var body: some View {
        label(isOpen, toggle)
            .background(ScreenRectReader(probe: probe))
            .onDisappear {
                // Navigating away with the menu open would otherwise leave a
                // panel floating over the next screen.
                if isOpen { MenuPresenter.shared.dismiss() }
            }
    }

    private func toggle() {
        if isOpen {
            MenuPresenter.shared.dismiss()
            return
        }
        // `.zero` means the view is not in a window — the snapshot and
        // accessibility harnesses host the tree without one, and there is
        // nowhere to put a menu.
        let anchor = probe.rect
        guard anchor != .zero else { return }
        isOpen = true
        MenuPresenter.shared.present(items(), from: anchor, in: probe.window) {
            isOpen = false
        }
    }
}

/// The ⋯ and ＋ on a detail header: a `CapsuleButton` that opens a Cadence
/// menu and stays lit for as long as it is open.
struct MenuButton: View {
    var systemImage: String
    /// Required: a glyph alone says nothing aloud, and it doubles as the
    /// tooltip.
    var accessibilityLabel: String
    var items: () -> [MenuItem]

    var body: some View {
        MenuAnchor(items: items) { isOpen, toggle in
            CapsuleButton(systemImage: systemImage,
                          isActive: isOpen,
                          accessibilityLabel: accessibilityLabel,
                          action: toggle)
                .help(accessibilityLabel)
        }
    }
}

// MARK: - Right-click

/// Catches a right-click and nothing else.
///
/// The trick is in `hitTest`: AppKit asks which view is under a point without
/// saying why, but the event that prompted the question is on `NSApp`. Looking
/// at it means this view can claim right-clicks while staying completely
/// transparent to left ones — so a row keeps its tap, its double-tap and, in a
/// `List`, its drag-to-reorder, none of which this ever sees.
private final class RightClickView: NSView {
    var onRightClick: ((CGPoint, NSWindow?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return super.hitTest(point)
        case .leftMouseDown:
            // Control-click is the other way to open a context menu, and the
            // only one available on a trackpad set to a single button.
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            return flags.contains(.control) ? super.hitTest(point) : nil
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) { report(event) }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        report(event)
    }

    private func report(_ event: NSEvent) {
        guard let window else { return }
        onRightClick?(window.convertPoint(toScreen: event.locationInWindow), window)
    }

    /// Nothing is drawn, so there is no reason to make AppKit ask.
    override var isOpaque: Bool { false }
}

private struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (CGPoint, NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RightClickView(frame: .zero)
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RightClickView)?.onRightClick = onRightClick
    }
}

extension View {
    /// A Cadence menu on right-click, in place of `.contextMenu`.
    ///
    /// `.contextMenu` hands presentation to AppKit, which is the whole of the
    /// complaint in #23 — the verbs were already right, the surface was not.
    /// This catches the click itself and opens the same panel the header
    /// buttons do.
    ///
    /// `onOpen` runs before the menu appears, for the call sites that want the
    /// row selected first: a menu that fired on a row nobody can see the
    /// outline of is a menu you have to guess the subject of.
    func cadenceContextMenu(onOpen: @escaping () -> Void = {},
                            _ items: @escaping () -> [MenuItem]) -> some View {
        overlay {
            RightClickCatcher { point, window in
                onOpen()
                MenuPresenter.shared.present(items(), at: point, in: window)
            }
        }
    }
}
