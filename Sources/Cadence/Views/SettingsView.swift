import SwiftUI
import CadenceCore

/// The Preferences window — issue #71. `CadenceApp` had only a `WindowGroup`, so
/// there was nowhere for a setting to live even once one existed. This is the
/// window and its wiring; each row's own behaviour is the concern of the issue
/// that adds it.
///
/// Built from `Tokens` rather than a stock `Form`: the app is one custom dark
/// surface end to end, and a system-drawn settings pane reads as a different
/// program. The shape follows `TrackInfoSheet` and `PlaylistNameSheet`.
struct SettingsView: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        @Bindable var playback = playback

        return VStack(alignment: .leading, spacing: Tokens.Space.xxl) {
            Text("Preferences")
                .font(Tokens.Typography.sans(16, .bold))
                .foregroundStyle(Tokens.Palette.textPrimary)

            SettingsSection("Playback") {
                SettingsRow(
                    "ReplayGain",
                    caption: "Even out loudness differences between tracks and albums."
                ) {
                    SegmentedPicker(
                        selection: $playback.replayGainMode,
                        options: ReplayGainMode.allCases,
                        label: \.label
                    )
                }
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 460, alignment: .leading)
        .background(Tokens.Palette.surface)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Building blocks

/// A titled group of rows. The heading is the same mono, wide-tracked label the
/// rest of the app uses for sections.
struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                content
            }
        }
    }
}

/// One setting: a name, an optional line of explanation, and its control on the
/// trailing edge.
struct SettingsRow<Control: View>: View {
    var name: String
    var caption: String?
    @ViewBuilder var control: Control

    init(_ name: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.name = name
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.l) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(name)
                    .font(Tokens.Typography.sans(13, .semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                if let caption {
                    Text(caption)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tokens.Space.l)
            control
        }
    }
}

/// A row of pills, one selected. Small enough for a Preferences row and styled
/// like the rest of the app rather than an `NSSegmentedControl`.
struct SegmentedPicker<Option: Hashable>: View {
    @Binding var selection: Option
    var options: [Option]
    var label: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(Tokens.Typography.sans(12, .semibold))
                        .foregroundStyle(isSelected
                                         ? Tokens.Palette.textPrimary
                                         : Tokens.Palette.textSecondary)
                        .padding(.horizontal, Tokens.Space.m)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                             style: .continuous)
                                .fill(isSelected ? Tokens.Palette.navActive : .clear)
                        }
                }
                .plainControl()
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.fieldBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.fieldBorder, lineWidth: 1)
        }
    }
}
