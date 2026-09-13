import SwiftUI
import CadenceCore

/// The window's own chrome. The mock paints three traffic-light circles; a
/// native window with `.hiddenTitleBar` already has real ones, so this reserves
/// their space instead of drawing imitations.
struct TitleBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        @Bindable var model = model

        HStack(spacing: Tokens.Space.l) {
            Color.clear.frame(width: Tokens.Layout.trafficLightInset, height: 1)

            HStack(spacing: Tokens.Space.xs) {
                NavigationChevron(direction: .backward, isEnabled: model.canGoBack) {
                    model.goBack()
                }
                NavigationChevron(direction: .forward, isEnabled: model.canGoForward) {
                    model.goForward()
                }
            }

            SearchTrigger()
                .frame(maxWidth: Tokens.Layout.searchFieldMaxWidth)
                .frame(maxWidth: .infinity)

            // Balances the chevrons on the left so the field stays optically
            // centred, and gives Preferences a way in besides ⌘,.
            HStack(spacing: Tokens.Space.xs) {
                Spacer(minLength: 0)
                IconButton(systemImage: "gearshape", label: "Preferences",
                           glyphSize: 13, side: 26,
                           isActive: model.screen == .settings) {
                    if model.screen != .settings { model.show(.settings) }
                }
            }
            .frame(width: 92)
        }
        .padding(.horizontal, Tokens.Space.l)
        .frame(height: Tokens.Layout.titleBarHeight)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: 0x1F1F24))
                .frame(height: 1)
        }
        .background(Tokens.Palette.chrome)
    }
}

private struct NavigationChevron: View {
    enum Direction { case backward, forward }

    var direction: Direction
    var isEnabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .backward ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled
                                 ? (isHovering ? Color(hex: 0xC9C9D2) : Color(hex: 0x6E6E78))
                                 : Color(hex: 0x43434C))
                .frame(width: 26, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .fill(isEnabled && isHovering ? Color(hex: 0x1E1E24) : .clear)
                }
        }
        .plainControl()
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(direction == .backward ? "Back" : "Forward")
    }
}

// MARK: - Search

/// The title bar's own half of search: a static button that opens
/// `SearchModal`, which owns the text field itself — the Spotify/Claude
/// command-palette pattern, not a field with a dropdown hanging off it.
struct SearchTrigger: View {
    @Environment(AppModel.self) private var model
    // Optional so the snapshot, a11y and benchmark harnesses can host this
    // view without one — same reasoning as `TextEntryMonitor`'s environment.
    @Environment(SearchFocusRequester.self) private var focusRequester: SearchFocusRequester?
    @State private var isHovering = false

    var body: some View {
        Button {
            model.isSearching = true
            focusRequester?.requestFocus()
        } label: {
            HStack(spacing: Tokens.Space.s + 2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x7A7A85))
                Text("Search artists, albums, tracks")
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundStyle(Color(hex: 0x7A7A85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(model.isSearching || isHovering
                          ? Tokens.Palette.fieldFocusBackground
                          : Tokens.Palette.fieldBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(model.isSearching
                                  ? Tokens.Palette.fieldFocusBorder
                                  : Tokens.Palette.fieldBorder, lineWidth: 1)
            }
        }
        .plainControl()
        .onHover { isHovering = $0 }
        .accessibilityLabel("Search library")
    }
}

