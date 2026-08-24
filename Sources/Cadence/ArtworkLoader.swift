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
    /// Decoded covers, bounded by resident bitmap size rather than count — a
    /// 600pt header image and a 32pt row icon cost very different amounts of
    /// memory for the same one slot. `DiskArtworkStore` caches the encoded
    /// bytes below this the same way, at a smaller limit, since a decoded
    /// bitmap is the bigger of the two.
    private let images = NSCache<NSString, NSImage>()
    /// Ids already tried and found to have no art, so a missing cover is not
    /// re-requested on every redraw. Unbounded on purpose: it holds only
    /// keys, and is bounded in practice by the size of the library.
    private var misses: Set<String> = []
    private var inFlight: Set<String> = []
    /// Bumped whenever a new image lands in `images`. Observation instruments
    /// stored properties, not the objects they point to, so mutating the
    /// cache in place — as `NSCache` requires — would otherwise never tell a
    /// waiting view that its artwork arrived.
    private var generation = 0

    /// Roughly a screenful or two of covers across the sizes the app
    /// actually requests (32–600pt, so up to 1200px on a side at retina).
    private static let costLimit = 150 * 1_024 * 1_024

    init(store: DiskArtworkStore?) {
        self.store = store
        images.totalCostLimit = Self.costLimit
    }

    /// `size` is the longest edge in points; the store cuts a thumbnail to
    /// match rather than handing back a full-resolution cover.
    func image(for id: Artwork.ID?, size: Int) -> NSImage? {
        _ = generation // establishes the Observation dependency even on a cache hit
        guard let id, let store else { return nil }
        let key = "\(id)-\(size)"
        if let image = images.object(forKey: key as NSString) { return image }
        guard !misses.contains(key), !inFlight.contains(key) else { return nil }

        inFlight.insert(key)
        Task { [weak self] in
            // Retina: ask for twice the point size so the thumbnail is sharp.
            let data = try? await store.thumbnail(for: id, maxPixelSize: size * 2)
            guard let self else { return }
            self.inFlight.remove(key)
            if let data, let image = NSImage(data: data) {
                self.images.setObject(image, forKey: key as NSString, cost: Self.decodedCost(of: image))
                self.generation += 1
            } else {
                self.misses.insert(key)
            }
        }
        return nil
    }

    /// Resident bitmap size, not the encoded byte count `data` arrived as —
    /// that is what stays in memory once `NSImage` has decoded it.
    private static func decodedCost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4
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

// MARK: - Rendered search focus

private struct SearchFocusRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draws the search field as though it held keyboard focus, suggestions
    /// and all. Focus belongs to the key window, and the snapshot harness
    /// renders into an off-screen window that never becomes one — without
    /// this, the one state that can hide behind the library cannot be shot.
    var rendersSearchFocused: Bool {
        get { self[SearchFocusRenderKey.self] }
        set { self[SearchFocusRenderKey.self] = newValue }
    }
}
