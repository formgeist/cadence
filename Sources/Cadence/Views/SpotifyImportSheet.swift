import SwiftUI
import CadenceDesign
import CadenceCore

/// Paste a Spotify playlist link, get a Cadence playlist of the songs the
/// library has. Same shape as the naming sheet — one field, Return finishes —
/// with a sign-in step in front of it the first time.
struct SpotifyImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(SpotifyImporter.self) private var importer
    @Environment(\.dismiss) private var dismiss

    @State private var link = ""
    @FocusState private var isFocused: Bool

    private var isBusy: Bool {
        importer.state == .signingIn || importer.state == .importing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Import Spotify playlist")
                    .font(Tokens.Typography.sans(16, .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(subtitle)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if importer.isSignedIn {
                linkField
            }

            if case .failed(let message) = importer.state {
                Text(message)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Tokens.Space.s) {
                if importer.isSignedIn {
                    CapsuleButton(title: "Sign Out") { importer.signOut() }
                        .disabled(isBusy)
                }
                Spacer(minLength: 0)
                CapsuleButton(title: "Cancel") { dismiss() }
                if importer.isSignedIn {
                    CapsuleButton(title: importer.state == .importing ? "Importing…" : "Import",
                                  kind: .filled, action: commit)
                        .disabled(isBusy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    CapsuleButton(title: importer.state == .signingIn
                                  ? "Waiting for Spotify…" : "Connect Spotify…",
                                  kind: .filled) {
                        Task { await importer.connect() }
                    }
                    .disabled(isBusy || !importer.isConfigured)
                }
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 420)
        .background(Tokens.Palette.popover)
        .onAppear {
            importer.clearFailure()
            isFocused = true
        }
        .onExitCommand { dismiss() }
    }

    private var linkField: some View {
        TextField("https://open.spotify.com/playlist/…", text: $link)
            .textFieldStyle(.plain)
            .font(Tokens.Typography.sans(13.5, .medium))
            .foregroundStyle(Tokens.Palette.textPrimary)
            .focused($isFocused)
            .textEntryFocus(isFocused)
            .onSubmit(commit)
            .disabled(isBusy)
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
            .accessibilityLabel("Spotify playlist link")
    }

    private var subtitle: String {
        if !importer.isConfigured {
            return "No Spotify app is configured in this build."
        }
        if !importer.isSignedIn {
            return "Connect your Spotify account to read playlists you own "
                + "or collaborate on."
        }
        return "Songs that are in your library go into a new playlist. "
            + "The rest are skipped."
    }

    private func commit() {
        guard !isBusy, !link.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let link = link
        Task {
            if await importer.importPlaylist(from: link, into: model) {
                dismiss()
            }
        }
    }
}
