import SwiftUI
import CadenceCore
import CadenceLibrary

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

/// The import strip. Sits under the title bar while a scan runs, then leaves.
struct ImportProgressBar: View {
    @Environment(LibraryImporter.self) private var importer

    var body: some View {
        if let progress = importer.progress {
            HStack(spacing: Tokens.Space.m) {
                SectionLabel("Importing", size: 9.5, color: Tokens.Palette.accent)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.Palette.trackGroove)
                        Capsule()
                            .fill(Tokens.Palette.accent)
                            .frame(width: progress.fraction * geometry.size.width)
                    }
                    .frame(height: 3)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 12)
                .accessibilityHidden(true)

                Text(summary(progress))
                    .font(Tokens.Typography.mono(10.5))
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .monospacedDigit()
                    .accessibilityLabel("Imported \(progress.processed) of \(progress.found)")
                    // A filename column that resizes with every file makes the
                    // whole strip twitch.
                    .frame(width: 190, alignment: .trailing)

                Button("Cancel") { importer.cancel() }
                    .plainControl()
                    .font(Tokens.Typography.sans(11.5, .semibold))
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .padding(.horizontal, Tokens.Space.l)
            .padding(.vertical, Tokens.Space.s)
            .background(Tokens.Palette.chrome)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(hex: 0x1F1F24)).frame(height: 1)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func summary(_ progress: LibraryScanner.Progress) -> String {
        guard progress.found > 0 else { return "scanning folder…" }
        return "\(progress.processed) / \(progress.found)"
    }
}
