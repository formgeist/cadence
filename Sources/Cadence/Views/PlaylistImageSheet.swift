import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CadenceCore

/// Sets, replaces, or clears the cover shown for one playlist.
///
/// By default a playlist shows its albums' covers tiled; this is how you swap
/// in a picture of your own. Like `ArtistImageSheet`, choices are staged and
/// only applied on Save, so Cancel is a true no-op.
struct PlaylistImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var playlist: Playlist

    private enum Draft: Equatable {
        case unchanged
        case replace(URL)
        case remove
    }

    @State private var draft: Draft = .unchanged

    /// The playlist as the model has it now: the row this sheet was opened with
    /// is a snapshot.
    private var current: Playlist { model.playlist(id: playlist.id) ?? playlist }
    private var hasCustomCover: Bool { current.artworkID != nil }

    private var canRemove: Bool {
        switch draft {
        case .replace: return true
        case .remove: return false
        case .unchanged: return hasCustomCover
        }
    }

    private var canSave: Bool { draft != .unchanged }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Edit playlist cover")
                    .font(Tokens.Typography.sans(16, .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(playlist.name)
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
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card,
                                                    style: .continuous))
                } else {
                    ArtworkView(artworkID: nil, cornerRadius: Tokens.Radius.card,
                                displaySize: 132)
                }
            case .remove:
                // What removing lands on: the tiled album covers.
                CoverMosaic(artworkIDs: model.coverIDs(forPlaylist: defaultCover),
                            cornerRadius: Tokens.Radius.card, displaySize: 132)
            case .unchanged:
                CoverMosaic(artworkIDs: model.coverIDs(forPlaylist: current),
                            cornerRadius: Tokens.Radius.card, displaySize: 132)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    /// The playlist with its own cover set aside, to preview the fallback.
    private var defaultCover: Playlist {
        var copy = current
        copy.artworkID = nil
        return copy
    }

    private var explanation: String {
        switch draft {
        case .replace:
            return "The chosen image replaces this playlist’s cover everywhere it shows."
        case .remove:
            return "Cadence goes back to tiling covers from the albums in this playlist."
        case .unchanged:
            return hasCustomCover
                ? "This playlist uses an image you set. Choose another, or remove it to fall back to album art."
                : "This playlist shows covers from its albums. Choose an image to override it."
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        panel.message = "Choose a cover for \(playlist.name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft = .replace(url)
    }

    private func commit() {
        let draft = draft
        let playlist = current
        dismiss()
        Task {
            switch draft {
            case .replace(let url):
                await model.setPlaylistImage(fromFile: url, for: playlist)
            case .remove:
                await model.removePlaylistImage(for: playlist)
            case .unchanged:
                break
            }
        }
    }
}
