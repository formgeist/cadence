import SwiftUI
import AppKit
import Observation
import CadenceCore
import CadenceLibrary

/// Bridges the async artwork store to SwiftUI's synchronous `body`.
///
/// A view asks for an image and gets whatever is already decoded — usually
/// nothing, the first time. The load is kicked off in the background and the
/// resulting `@Observable` mutation redraws just the views that asked. That
/// keeps a scrolling grid from ever awaiting on the main actor, which is the
/// difference between a smooth grid and a stuttering one.
@MainActor
@Observable
final class ArtworkLoader {

    private let store: DiskArtworkStore?
    private var images: [String: NSImage] = [:]
    /// Ids already tried and found to have no art, so a missing cover is not
    /// re-requested on every redraw.
    private var misses: Set<String> = []
    private var inFlight: Set<String> = []

    init(store: DiskArtworkStore?) {
        self.store = store
    }

    /// `size` is the longest edge in points; the store cuts a thumbnail to
    /// match rather than handing back a full-resolution cover.
    func image(for id: Artwork.ID?, size: Int) -> NSImage? {
        guard let id, let store else { return nil }
        let key = "\(id)-\(size)"
        if let image = images[key] { return image }
        guard !misses.contains(key), !inFlight.contains(key) else { return nil }

        inFlight.insert(key)
        Task { [weak self] in
            // Retina: ask for twice the point size so the thumbnail is sharp.
            let data = try? await store.thumbnail(for: id, maxPixelSize: size * 2)
            guard let self else { return }
            self.inFlight.remove(key)
            if let data, let image = NSImage(data: data) {
                self.images[key] = image
            } else {
                self.misses.insert(key)
            }
        }
        return nil
    }
}


// MARK: - Silent playback

private struct SilentPlaybackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the mock engine stands in for a decoder.
    var isSilentPlayback: Bool {
        get { self[SilentPlaybackKey.self] }
        set { self[SilentPlaybackKey.self] = newValue }
    }
}
