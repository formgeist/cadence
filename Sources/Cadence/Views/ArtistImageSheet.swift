import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CadenceCore

/// Sets, replaces, or clears the picture shown for one artist.
///
/// An artist is an aggregate of tracks, not a row you can retag, so the name
/// stays read-only here — the same line `TrackInfoSheet` draws. The image is
/// the one thing that is genuinely the user's to choose: by default it is
/// whichever cover the artist released first, and this is how you override
/// that.
struct ArtistImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var artist: Artist

    /// What Save will do. Kept as an intent rather than applied on click so
    /// Cancel is a true no-op and the preview can show the outcome first.
    private enum Draft: Equatable {
        case unchanged
        case replace(URL)
        case remove
    }

    @State private var draft: Draft = .unchanged

    private var hasCustomImage: Bool { model.hasCustomImage(forArtist: artist.name) }

    /// Whether the preview is currently showing something the user could clear —
    /// an existing custom image they haven't already staged for removal, or a
    /// replacement they just picked.
    private var canRemove: Bool {
        switch draft {
        case .replace: return true
        case .remove: return false
        case .unchanged: return hasCustomImage
        }
    }

    private var canSave: Bool { draft != .unchanged }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Edit artist")
                    .font(Tokens.Typography.sans(16, .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(artist.name)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
            }

            HStack(spacing: Tokens.Space.xl) {
                preview
                    .frame(width: 132, height: 132)

                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    CapsuleButton(title: "Choose Image…", systemImage: "photo") {
                        chooseImage()
                    }
                    CapsuleButton(title: "Remove Image", systemImage: "arrow.uturn.backward") {
                        draft = .remove
                    }
                    .disabled(!canRemove)

                    Text(explanation)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Tokens.Space.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: Tokens.Space.s) {
                Spacer(minLength: 0)
                CapsuleButton(title: "Cancel") { dismiss() }
                CapsuleButton(title: "Save", kind: .filled, action: commit)
                    .disabled(!canSave)
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 460)
        .background(Tokens.Palette.popover)
        .onExitCommand { dismiss() }
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            switch draft {
            case .replace(let url):
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                        .overlay { Circle().stroke(Tokens.Palette.placeholderBorder, lineWidth: 1) }
                } else {
                    ArtworkView(artworkID: nil, isCircular: true, displaySize: 132)
                }
            case .remove:
                // The album-cover fallback, i.e. what removing lands on.
                ArtworkView(artworkID: model.artworkID(forArtist: artist.name),
                            isCircular: true, displaySize: 132)
            case .unchanged:
                ArtworkView(artworkID: model.artworkID(forArtist: artist.name),
                            isCircular: true, displaySize: 132)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    private var explanation: String {
        switch draft {
        case .replace:
            return "The chosen image replaces the artist’s auto artwork everywhere it shows."
        case .remove:
            return "Cadence goes back to using the first album cover this artist released."
        case .unchanged:
            return hasCustomImage
                ? "This artist uses an image you set. Choose another, or remove it to fall back to album art."
                : "This artist uses the cover of their first album. Choose an image to override it."
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        panel.message = "Choose an image for \(artist.name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft = .replace(url)
    }

    private func commit() {
        let draft = draft
        let name = artist.name
        dismiss()
        Task {
            switch draft {
            case .replace(let url):
                await model.setArtistImage(fromFile: url, forArtist: name)
            case .remove:
                await model.removeArtistImage(forArtist: name)
            case .unchanged:
                break
            }
        }
    }
}
