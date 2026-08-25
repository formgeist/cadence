import SwiftUI
import Observation

/// Lets a menu command ask the search field to take the keyboard — the
/// opposite direction from `TextEntryMonitor`, which lets a field tell the
/// menu bar it already has it.
///
/// There's no `@FocusState` a menu command can reach directly: focus lives on
/// the view that owns it. `SearchField` observes `token` instead of the
/// command calling into the field itself. See #72.
@MainActor
@Observable
final class SearchFocusRequester {
    private(set) var token = 0

    func requestFocus() { token += 1 }
}
