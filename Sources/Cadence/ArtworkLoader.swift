import SwiftUI
import AppKit
import CoreImage
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
            // A `forget(_:)` while this was in flight has already dropped the
            // key and likely kicked off a fresh attempt — this one must not
            // land its result, least of all resurrect a miss the retry is
            // meant to clear.
            guard self.inFlight.remove(key) != nil else { return }
            if let data, let image = NSImage(data: data) {
                self.images.setObject(image, forKey: key as NSString, cost: Self.decodedCost(of: image))
                self.generation += 1
            } else {
                self.misses.insert(key)
            }
        }
        return nil
    }

    /// Drops every cached trace of one artwork id — a decoded image, a recorded
    /// miss, the in-flight guard — so the next request starts over.
    ///
    /// The miss set exists because a track with no embedded cover never grows
    /// one mid-session, so re-asking on every redraw is pure waste. A custom
    /// artist image breaks that assumption: the id lands in the library the
    /// same instant its bytes are written, and a redraw that raced the write
    /// (or a launch rescan's prune briefly sweeping the fresh file) would
    /// otherwise cache the miss and leave the header on the placeholder until
    /// the app is relaunched. `AppModel` calls this once the write has settled.
    func forget(_ id: Artwork.ID) {
        let prefix = "\(id)-"
        misses = misses.filter { !$0.hasPrefix(prefix) }
        inFlight = inFlight.filter { !$0.hasPrefix(prefix) }
        bloomMisses = bloomMisses.filter { !$0.hasPrefix(prefix) }
        generation += 1
    }

    /// Resident bitmap size, not the encoded byte count `data` arrived as —
    /// that is what stays in memory once `NSImage` has decoded it.
    private static func decodedCost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4
    }

    // MARK: - Ambient bloom

    private let bloomCache = NSCache<NSString, BloomPalette>()
    private var bloomMisses: Set<String> = []
    private var bloomInFlight: Set<String> = []

    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Two soft colors sampled from opposite corners of the cover, for the
    /// immersive view's ambient background glow. Piggybacks on the same
    /// decode pipeline as `image(for:size:)`, at a much smaller size —
    /// averaging the full 600pt cover would be needlessly slow for two
    /// numbers a heavy blur immediately smooths out anyway.
    func bloomColors(for id: Artwork.ID?) -> (Color, Color)? {
        _ = generation // same redraw dependency as `image(for:size:)`
        guard let id else { return nil }
        let key = "\(id)-bloom"
        if let cached = bloomCache.object(forKey: key as NSString) {
            return (cached.primary, cached.secondary)
        }
        guard !bloomMisses.contains(key), !bloomInFlight.contains(key) else { return nil }
        // Requesting the thumbnail here (rather than requiring a caller to
        // have already asked for one) both triggers the decode and shares
        // its cache entry with any other 48pt use.
        guard let thumbnail = image(for: id, size: 48) else { return nil }

        bloomInFlight.insert(key)
        Task { [weak self] in
            guard let self else { return }
            defer { self.bloomInFlight.remove(key) }
            guard let colors = Self.extractBloomColors(from: thumbnail) else {
                self.bloomMisses.insert(key)
                return
            }
            self.bloomCache.setObject(
                BloomPalette(primary: colors.0, secondary: colors.1),
                forKey: key as NSString)
            self.generation += 1
        }
        return nil
    }

    /// Averages over the visual top-left and bottom-right of the cover.
    /// Core Image's Y axis runs bottom-to-top, so "visually top" is the
    /// *upper* half of the extent, not the lower one.
    private static func extractBloomColors(from image: NSImage) -> (Color, Color)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        let topLeft = CGRect(
            x: extent.minX, y: extent.minY + extent.height * 0.35,
            width: extent.width * 0.65, height: extent.height * 0.65)
        let bottomRight = CGRect(
            x: extent.minX + extent.width * 0.35, y: extent.minY,
            width: extent.width * 0.65, height: extent.height * 0.65)

        guard let primary = averageColor(of: ciImage, in: topLeft),
              let secondary = averageColor(of: ciImage, in: bottomRight)
        else { return nil }
        return (primary, secondary)
    }

    private static func averageColor(of image: CIImage, in rect: CGRect) -> Color? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return Color(
            red: Double(bitmap[0]) / 255,
            green: Double(bitmap[1]) / 255,
            blue: Double(bitmap[2]) / 255)
    }
}

/// Boxes a pair of `Color`s so they can sit in an `NSCache`, which requires
/// reference types.
private final class BloomPalette {
    let primary: Color
    let secondary: Color

    init(primary: Color, secondary: Color) {
        self.primary = primary
        self.secondary = secondary
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
