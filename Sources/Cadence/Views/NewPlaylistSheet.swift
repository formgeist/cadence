import SwiftUI
import CadenceCore

/// Naming the playlist is the whole dialog. One field, already filled and
/// selected, and Return finishes it — the sidebar's plus is meant to be a
/// two-second detour, not a form.
struct NewPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("New playlist")
                    .font(Tokens.Typography.sans(16, .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text("Name it now — tracks can go in whenever.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }

            TextField("Playlist name", text: $name)
                .textFieldStyle(.plain)
                .font(Tokens.Typography.sans(13.5, .medium))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .focused($isFocused)
                .onSubmit(create)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(Tokens.Palette.fieldFocusBackground)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .strokeBorder(isFocused
                                      ? Tokens.Palette.fieldFocusBorder
                                      : Tokens.Palette.fieldBorder, lineWidth: 1)
                }
                .accessibilityLabel("Playlist name")

            HStack(spacing: Tokens.Space.s) {
                Spacer(minLength: 0)
                CapsuleButton(title: "Cancel") { dismiss() }
                CapsuleButton(title: "Create", kind: .filled, action: create)
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 380)
        .background(Tokens.Palette.popover)
        .onAppear {
            name = model.suggestedPlaylistName
            isFocused = true
        }
        // A sheet with a focused text field swallows Escape unless it is asked
        // for by name.
        .onExitCommand { dismiss() }
    }

    private func create() {
        let chosen = name
        dismiss()
        Task { await model.createPlaylist(named: chosen) }
    }
}
