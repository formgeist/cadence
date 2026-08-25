import SwiftUI
import CadenceCore

/// What a fresh install shows. Not a shrug — the one thing to do here is name
/// a folder, so that is the only thing on screen.
struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryImporter.self) private var importer

    var body: some View {
        VStack(spacing: Tokens.Space.l) {
            Spacer()

            ZStack {
                Circle()
                    .strokeBorder(Tokens.Palette.accent.opacity(0.25), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .ultraLight))
                    .foregroundStyle(Tokens.Palette.accent)
            }
            .accessibilityHidden(true)

            VStack(spacing: Tokens.Space.s) {
                Text("No music yet")
                    .font(Tokens.Typography.sans(22, .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Tokens.Palette.textPrimary)

                Text("Point Cadence at a folder of FLAC files and it will read the tags,\nextract the artwork, and build your library.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            CapsuleButton(title: "Choose Music Folder…",
                          systemImage: "folder", kind: .filled) {
                guard let folder = importer.chooseFolder() else { return }
                importer.importFolders([folder]) {
                    Task { await model.load() }
                }
            }
            .padding(.top, Tokens.Space.xs)

            if let failure = model.storeFailure {
                Text(failure)
                    .font(Tokens.Typography.sans(11, .medium))
                    .foregroundStyle(Tokens.Palette.accent)
                    .padding(.top, Tokens.Space.s)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.surface)
    }
}
