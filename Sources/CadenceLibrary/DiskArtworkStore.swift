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
public actor DiskArtworkStore: ArtworkStore {

    private let root: URL
    private let originals: URL
    private let thumbnails: URL

    /// In front of the disk cache, so a scrolling grid re-reads nothing.
    private let memory = NSCache<NSString, NSData>()

    public init(root: URL) throws {
        self.root = root
        originals = root.appendingPathComponent("originals", isDirectory: true)
        thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        for directory in [originals, thumbnails] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        // Roughly 40 MB of decoded thumbnails; well past a screenful of grid.
        memory.totalCostLimit = 40 * 1_024 * 1_024
    }

    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Cadence/Artwork", isDirectory: true)
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
