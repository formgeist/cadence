import SwiftUI
import CadenceDesign
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
                CadenceIcon("waveform", size: 30)
                    .foregroundStyle(Tokens.Palette.accent)
            }
            .accessibilityHidden(true)

            VStack(spacing: Tokens.Space.s) {
                Text(model.pairedMacName.map { "Nothing from \($0) yet" } ?? "No music yet")
                    .font(Tokens.Typography.sans(22, .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Tokens.Palette.textPrimary)

                Text(message)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            if model.canEditLibrary {
                CapsuleButton(title: "Choose Music Folder…",
                              systemImage: "folder", kind: .filled) {
                    guard let folder = importer.chooseFolder() else { return }
                    importer.importFolders([folder]) {
                        Task { await model.load() }
                    }
                }
                .padding(.top, Tokens.Space.xs)
            } else {
                HStack(spacing: Tokens.Space.s) {
                    CapsuleButton(title: "Try Again") { Task { await model.load() } }
                    CapsuleButton(title: "Open Preferences", kind: .filled) {
                        model.show(.settings)
                    }
                }
                .padding(.top, Tokens.Space.xs)
            }

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

    private var message: String {
        guard let name = model.pairedMacName else {
            return "Point Cadence at a folder of FLAC files and it will read the tags,\n"
                + "extract the artwork, and build your library."
        }
        // An empty library from a Mac that did answer is a library with
        // nothing in it; one that did not answer is the usual case.
        if let error = model.loadError { return error }
        return "\(name) has no music in its library yet."
    }
}
