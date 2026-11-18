import Foundation
import CryptoKit
import CadenceCore

/// Cover art from another Mac, as the `ArtworkStore` the Mac app draws with.
///
/// A remote track's `artworkID` is the server's cover art id, so a cover is
/// fetched by the id the app already holds. Each answer is kept on disk,
/// one file per id and size, so a grid scrolled twice asks the Mac once, and
/// covers still show while the Mac is asleep. File names are a digest of the
/// id and size: the id is the server's, and is not trusted as a path.
///
/// Read-only, like `RemoteLibraryStore`: storing a cover throws
/// `RemoteError.readOnly`.
public final class RemoteArtworkStore: ArtworkStore {

    private let client: RemoteLibraryClient
    public let directory: URL

    public init(client: RemoteLibraryClient, directory: URL) {
        self.client = client
        self.directory = directory
    }

    public func store(_ data: Data) async throws -> Artwork.ID {
        throw RemoteError.readOnly
    }

    public func thumbnail(for id: Artwork.ID, maxPixelSize: Int) async throws -> Data? {
        try await cover(id, size: maxPixelSize)
    }

    public func full(for id: Artwork.ID) async throws -> Data? {
        try await cover(id, size: nil)
    }

    /// The cached bytes, or the Mac's answer. Nil for a cover the Mac does
    /// not have, which the app draws as a placeholder, and for one that is
    /// neither cached nor reachable.
    private func cover(_ id: Artwork.ID, size: Int?) async throws -> Data? {
        let file = file(for: id, size: size)
        if let cached = try? Data(contentsOf: file) { return cached }
        do {
            let data = try await client.coverArt(id: id, size: size)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        } catch let error as RemoteError where error == .notFound || error.isAbsence {
            return nil
        }
    }

    private func file(for id: Artwork.ID, size: Int?) -> URL {
        let name = "\(id)\u{0}\(size.map(String.init) ?? "full")"
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    /// Forgets every cached cover, as when the pairing is removed.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
