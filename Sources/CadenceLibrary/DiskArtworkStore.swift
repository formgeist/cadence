import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import CadenceCore

/// Content-addressed cover art on disk, with thumbnails generated on demand.
///
/// Two rules from PLAN.md §7 drive the whole design. Artwork is addressed by
/// the SHA-256 of its bytes, so the identical cover repeated across a box set
/// is stored once. And callers never get the full-resolution image for a list:
/// a 200-album grid of full-size JPEGs is hundreds of megabytes and visible
/// stutter, so thumbnails are cut with `CGImageSourceCreateThumbnailAtIndex`
/// and cached by `(id, size)`.
///
/// The two halves live under different roots, and the split is the point.
/// Thumbnails are derived from the originals and can always be cut again, so
/// they belong in Caches — that is what the directory is for. The originals do
/// not: for artwork lifted out of a tag, the bytes here are the only copy the
/// app holds, and the source is a metadata block inside a FLAC file that
/// nothing re-reads. macOS may evict anything under `~/Library/Caches` under
/// disk pressure and does not ask, and a rescan will not put it back — the
/// scanner skips files whose size and mtime are unchanged, which after an
/// eviction is all of them. So a library would silently and permanently lose
/// its covers with no user-reachable way to get them back.
///
/// Application Support is also backed up by Time Machine and Caches is not,
/// which is the right outcome for an image the user cannot regenerate.
public actor DiskArtworkStore: ArtworkStore {

    private let originals: URL
    private let thumbnails: URL

    /// In front of the disk cache, so a scrolling grid re-reads nothing.
    private let memory = NSCache<NSString, NSData>()

    /// Both halves under one root. Tests and the benchmark harness want a
    /// single throwaway directory; the app uses `makeDefault()`.
    public init(root: URL) throws {
        originals = root.appendingPathComponent("originals", isDirectory: true)
        thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        try Self.createDirectories(originals, thumbnails)
        // Roughly 40 MB of decoded thumbnails; well past a screenful of grid.
        memory.totalCostLimit = Self.memoryLimit
    }

    public init(originals: URL, thumbnails: URL) throws {
        self.originals = originals
        self.thumbnails = thumbnails
        try Self.createDirectories(originals, thumbnails)
        memory.totalCostLimit = Self.memoryLimit
    }

    private static let memoryLimit = 40 * 1_024 * 1_024

    private static func createDirectories(_ urls: URL...) throws {
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Default locations

    /// `~/Library/Application Support/Cadence/Artwork/originals`, in the same
    /// directory as `library.sqlite`.
    public static func defaultOriginalsURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent("originals", isDirectory: true)
    }

    /// `~/Library/Caches/Cadence/Artwork/thumbnails`.
    public static func defaultThumbnailsURL() throws -> URL {
        try defaultCacheRoot().appendingPathComponent("thumbnails", isDirectory: true)
    }

    private static func defaultCacheRoot() throws -> URL {
        try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Cadence/Artwork", isDirectory: true)
    }

    /// The store the app runs on, migrating any originals still sitting in
    /// Caches from before the split.
    public static func makeDefault() throws -> DiskArtworkStore {
        let originals = try defaultOriginalsURL()
        if let legacy = try? defaultCacheRoot()
            .appendingPathComponent("originals", isDirectory: true) {
            migrateOriginals(from: legacy, to: originals)
        }
        return try DiskArtworkStore(originals: originals,
                                    thumbnails: try defaultThumbnailsURL())
    }

    /// Moves originals out of the old cache root rather than orphaning them.
    /// They are content-addressed, so the filename is the hash of the bytes: a
    /// move needs no re-hashing and can never collide with a different image,
    /// and a file already at the destination is byte-identical, so the source
    /// is simply dropped.
    ///
    /// Best-effort by design. A store that cannot be migrated must not stop the
    /// app from opening, and anything left behind is still re-extractable with
    /// a forced rescan.
    static func migrateOriginals(from legacy: URL, to destination: URL) {
        let manager = FileManager.default
        guard legacy.standardizedFileURL != destination.standardizedFileURL,
              manager.fileExists(atPath: legacy.path)
        else { return }

        do {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return
        }

        let contents = (try? manager.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            if manager.fileExists(atPath: target.path) {
                try? manager.removeItem(at: url)
            } else {
                try? manager.moveItem(at: url, to: target)
            }
        }
        // Only once it is empty: anything still there is a file the move could
        // not take, and removing the directory would destroy it outright.
        if (try? manager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
            try? manager.removeItem(at: legacy)
        }
    }

    // MARK: - ArtworkStore

    @discardableResult
    public func store(_ data: Data) throws -> Artwork.ID {
        let id = Self.identifier(for: data)
        let url = originals.appendingPathComponent(id)
        // Content addressing means an existing file is byte-identical; writing
        // it again would be pure I/O for no change.
        guard !FileManager.default.fileExists(atPath: url.path) else { return id }
        try data.write(to: url, options: .atomic)
        return id
    }

    public func full(for id: Artwork.ID) throws -> Data? {
        let url = originals.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func thumbnail(for id: Artwork.ID, maxPixelSize: Int) throws -> Data? {
        let key = "\(id)-\(maxPixelSize)" as NSString
        if let cached = memory.object(forKey: key) { return cached as Data }

        let cacheURL = thumbnails.appendingPathComponent("\(id)-\(maxPixelSize).png")
        if let onDisk = try? Data(contentsOf: cacheURL) {
            memory.setObject(onDisk as NSData, forKey: key, cost: onDisk.count)
            return onDisk
        }

        guard let data = try full(for: id),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let thumbnail = output as Data
        try? thumbnail.write(to: cacheURL, options: .atomic)
        memory.setObject(thumbnail as NSData, forKey: key, cost: thumbnail.count)
        return thumbnail
    }

    // MARK: - Maintenance

    /// Deletes originals no track references any more. Thumbnails go with them.
    ///
    /// Two roots under different lifetimes: an original is only ever removed
    /// here, while a thumbnail may already have been evicted from Caches by the
    /// system. A missing thumbnail is nothing to report — the next request cuts
    /// it again from the original.
    public func prune(keeping ids: Set<Artwork.ID>) throws {
        let manager = FileManager.default
        for url in try manager.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil) {
            guard !ids.contains(url.lastPathComponent) else { continue }
            try? manager.removeItem(at: url)
        }
        for url in try manager.contentsOfDirectory(at: thumbnails, includingPropertiesForKeys: nil) {
            let id = url.deletingPathExtension().lastPathComponent
                .components(separatedBy: "-").dropLast().joined(separator: "-")
            guard !ids.contains(id) else { continue }
            try? manager.removeItem(at: url)
        }
        memory.removeAllObjects()
    }

    public static func identifier(for data: Data) -> Artwork.ID {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
