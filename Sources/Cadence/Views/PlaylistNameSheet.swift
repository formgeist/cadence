import SwiftUI
import CadenceCore

/// Naming the playlist is the whole dialog. One field, already filled and
/// selected, and Return finishes it — the sidebar's plus is meant to be a
/// two-second detour, not a form.
///
/// Renaming is the same dialog with a different verb. Splitting them would
/// mean two sheets that have to be kept looking alike, to no end: the question
/// being asked is identical.
struct PlaylistNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var naming: AppModel.Naming

    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var isRenaming: Bool {
        if case .rename = naming { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(isRenaming ? "Rename playlist" : "New playlist")
                    .font(Tokens.Typography.sans(16, .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(subtitle)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }

            TextField("Playlist name", text: $name)
                .textFieldStyle(.plain)
                .font(Tokens.Typography.sans(13.5, .medium))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .focused($isFocused)
                .textEntryFocus(isFocused)
                .onSubmit(commit)
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
                CapsuleButton(title: isRenaming ? "Rename" : "Create",
                              kind: .filled, action: commit)
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 380)
        .background(Tokens.Palette.popover)
        .onAppear {
            switch naming {
            case .create: name = model.suggestedPlaylistName
            case .rename(let playlist): name = playlist.name
            }
            isFocused = true
        }
        // A sheet with a focused text field swallows Escape unless it is asked
        // for by name.
        .onExitCommand { dismiss() }
    }

    /// Creating from an "Add to Playlist" menu already has tracks in hand, and
    /// saying so is the difference between a dialog that looks like it forgot
    /// them and one that clearly did not.
    private var subtitle: String {
        switch naming {
        case .create(let seed) where !seed.isEmpty:
            let count = seed.count == 1 ? "1 track" : "\(seed.count) tracks"
            return "\(count) will go in as soon as it exists."
        case .create:
            return "Name it now — tracks can go in whenever."
        case .rename:
            return "The tracks and their order stay as they are."
        }
    }

    private func commit() {
        let chosen = name
        let naming = naming
        dismiss()
        Task {
            switch naming {
            case .create(let seed):
                await model.createPlaylist(named: chosen, containing: seed.map(\.id))
            case .rename(let playlist):
                await model.renamePlaylist(playlist, to: chosen)
            }
        }
    }
}
