import SwiftUI
import Observation

/// Whether a text field in the app currently has the keyboard.
///
/// Menu key equivalents are dispatched from `NSApplication.sendEvent` *before*
/// the key window's responder chain sees the event. A bare-Space menu item is
/// the classic macOS consequence: Play/Pause claims the keystroke, and typing a
/// space into a text field toggles playback instead of inserting a character.
/// "slow hours" is exactly the kind of thing someone types into the search
/// field, and it would come out as "slowhours" with the record starting and
/// stopping twice on the way.
///
/// Space is still the right binding — every player has it — so the command is
/// disabled while a field is being typed into rather than given up. A disabled
/// menu item does not claim its key equivalent, so the keystroke carries on
/// down to the field editor, which is where it was going.
@MainActor
@Observable
final class TextEntryMonitor {

    /// Which fields hold focus, rather than a count. Focus can be gained and
    /// lost out of order — a sheet dismissing takes its field with it — and a
    /// counter that drifted would leave Play/Pause dead for the rest of the
    /// session, which is a worse bug than the one being fixed.
    private var focused: Set<UUID> = []

    var isEditing: Bool { !focused.isEmpty }

    func setFocus(_ isFocused: Bool, for field: UUID) {
        if isFocused {
            focused.insert(field)
        } else {
            focused.remove(field)
        }
    }
}

extension View {
    /// Tells the menu bar that this view is a text field, and whether it
    /// currently has the keyboard.
    ///
    /// Every `TextField` in the app wants this. It is a modifier rather than
    /// something the fields are trusted to remember because forgetting it is
    /// silent: the field simply loses spaces, and nothing in `make a11y` or the
    /// snapshot harness can see it — keyboard focus and the accessibility tree
    /// are different questions, and the snapshot window never becomes key.
    func textEntryFocus(_ isFocused: Bool) -> some View {
        modifier(TextEntryFocus(isFocused: isFocused))
    }
}

private struct TextEntryFocus: ViewModifier {
    // Optional so the snapshot, a11y and benchmark harnesses can host a view
    // tree without one. A missing monitor means no menu bar to protect.
    @Environment(TextEntryMonitor.self) private var monitor: TextEntryMonitor?
    @State private var field = UUID()

    var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isFocused) { _, focused in
                monitor?.setFocus(focused, for: field)
            }
            // A sheet dismissed while its field is focused never reports losing
            // it. Without this the app would be left believing someone is
            // still typing.
            .onDisappear { monitor?.setFocus(false, for: field) }
    }
}
