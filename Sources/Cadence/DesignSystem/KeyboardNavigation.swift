import SwiftUI

/// Arrow-key movement over a flat sequence of items laid out in `columns`
/// columns (1 for a single-column list). Shared by every grid and list built
/// from `LazyVGrid`/`LazyVStack` rather than `List`, which brings none of this
/// for free — see issue #7.
enum GridNavigation {
    enum Direction {
        case up, down, left, right

        init?(_ key: KeyEquivalent) {
            switch key {
            case .upArrow: self = .up
            case .downArrow: self = .down
            case .leftArrow: self = .left
            case .rightArrow: self = .right
            default: return nil
            }
        }

        /// `ScrollView` implements the same `moveUp:`/`moveDown:` responder
        /// actions for its own line-scrolling, and wins the arrow keys before
        /// a nested `.onKeyPress` ever sees them — confirmed by instrumenting
        /// the handler: `Return` and letters logged, `Down` never did.
        /// `.onMoveCommand` hooks those same selectors, so our handler is the
        /// one that answers instead of the scroll view.
        init?(_ command: MoveCommandDirection) {
            switch command {
            case .up: self = .up
            case .down: self = .down
            case .left: self = .left
            case .right: self = .right
            @unknown default: return nil
            }
        }

        /// From a raw `NSEvent.keyCode`, for the one place in the app that
        /// answers arrow keys via a local `NSEvent` monitor rather than
        /// `.onMoveCommand` — `SearchField`'s popover, where the search
        /// field's own text-editing responder answers `moveUp:`/`moveDown:`
        /// before either SwiftUI mechanism would ever see the event.
        init?(keyCode: UInt16) {
            switch keyCode {
            case 126: self = .up
            case 125: self = .down
            case 123: self = .left
            case 124: self = .right
            default: return nil
            }
        }
    }

    /// The index arrow keys should move focus to, clamped to the array's
    /// bounds rather than wrapping — running off the end of a row or the top
    /// of the grid holds still, the way it does in Finder. `nil` in means
    /// nothing is focused yet, and any direction starts at the first item.
    static func move(from index: Int?, by direction: Direction,
                     count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        let columns = max(1, columns)
        switch direction {
        case .left:
            return index > 0 ? index - 1 : index
        case .right:
            return index < count - 1 ? index + 1 : index
        case .up:
            let target = index - columns
            return target >= 0 ? target : index
        case .down:
            let target = index + columns
            return target < count ? target : index
        }
    }
}

/// Finder-style type-to-select: letters typed within `timeout` of each other
/// accumulate into one search string that must prefix-match; a pause starts a
/// new search. A reference type so a view can hold one in `@State` without
/// fighting SwiftUI over mutating-struct semantics on every keystroke.
@MainActor
final class TypeAheadBuffer {
    private var buffer = ""
    private var lastKeyTime = Date.distantPast
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 0.7) { self.timeout = timeout }

    /// Feeds one typed character in and returns the index of the matching
    /// item in `keys`, searching from just after `current` and wrapping
    /// around. Two letters typed quickly narrow the search ("sl" finds "Slow
    /// Hours" before "Something Else"); the same letter typed repeatedly
    /// cycles through everything starting with it, Finder-style, because a
    /// buffer that stops matching anything resets to just the latest key.
    func index(for character: Character, current: Int?, keys: [String]) -> Int? {
        let now = Date()
        if now.timeIntervalSince(lastKeyTime) > timeout { buffer = "" }
        lastKeyTime = now
        buffer.append(character)

        guard !keys.isEmpty else { return nil }
        let start = (current ?? -1) + 1
        if let match = Self.firstMatch(for: buffer, from: start, in: keys) {
            return match
        }
        buffer = String(character)
        return Self.firstMatch(for: buffer, from: start, in: keys)
    }

    private static func firstMatch(for prefix: String, from start: Int,
                                   in keys: [String]) -> Int? {
        guard !prefix.isEmpty else { return nil }
        let count = keys.count
        for offset in 0..<count {
            let index = (start + offset) % count
            if keys[index].range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                return index
            }
        }
        return nil
    }
}

extension View {
    /// A ring drawn just outside `shape` while `isFocused`, marking arrow-key
    /// focus as its own state — distinct from hover, from a click selection,
    /// and from "now playing", which the accent colour already speaks for
    /// elsewhere on these cards and rows.
    @ViewBuilder
    func keyboardFocusRing(_ isFocused: Bool, in shape: some InsettableShape) -> some View {
        overlay {
            if isFocused {
                shape
                    .strokeBorder(Tokens.Palette.accent, lineWidth: 2)
                    .padding(-5)
            }
        }
    }
}
