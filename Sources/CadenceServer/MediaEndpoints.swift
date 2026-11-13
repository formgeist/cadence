import Foundation
import CadenceCore
import CadenceLibrary

/// The endpoints that answer with bytes instead of an envelope: audio and
/// cover art.
///
/// Both follow one rule. **The request names a thing by id; the server
/// decides where that thing is.** A song id is looked up in the library and
/// the library's own record says which file to open. A cover id is checked
/// to be a content address before it goes anywhere near the artwork folder.
/// Nothing a client sends is ever used as, or joined into, a path.
extension LibraryEndpoints {

    // MARK: - stream, download

    /// The original file, whole or the byte range asked for.
    ///
    /// `stream` and `download` are the same here: there is no transcoding, so
    /// the protocol's `maxBitRate` and `format` parameters have nothing to
    /// change and are ignored.
    func audio(_ request: HTTPRequest) async throws -> HTTPResponse {
        let id = try Self.required("id", in: request)
        guard let trackID = WireID.track(from: id),
              let track = try await library.track(withID: trackID) else {
            throw EndpointFailure.notFound
        }
        // In the library but not on disk: an unmounted volume, or a file
        // removed since the last scan. The same answer as an unknown id.
        guard let size = FileSource.size(of: track.url) else { throw EndpointFailure.notFound }

        let contentType = MediaType.audio(forExtension: track.url.pathExtension.lowercased())
        let acceptRanges = (name: "Accept-Ranges", value: "bytes")

        switch ByteRange.resolve(request.headers["range"], size: size) {
        case .whole:
            return HTTPResponse(
                status: .ok, contentType: contentType, headers: [acceptRanges],
                file: FileBody(url: track.url, offset: 0, length: size))
        case .partial(let offset, let length):
            return HTTPResponse(
                status: .partialContent, contentType: contentType,
                headers: [acceptRanges,
                          (name: "Content-Range",
                           value: "bytes \(offset)-\(offset + length - 1)/\(size)")],
                file: FileBody(url: track.url, offset: offset, length: length))
        case .unsatisfiable:
            return HTTPResponse(
                status: .rangeNotSatisfiable,
                headers: [acceptRanges, (name: "Content-Range", value: "bytes */\(size)")])
        }
    }

    // MARK: - getCoverArt

    /// The pixel sizes a cover is served at. A requested size is rounded up
    /// to the next of these.
    ///
    /// The artwork store keeps one thumbnail file per cover per size. Without
    /// this, a client could ask for every size from 1 to 10,000 and fill the
    /// disk a file at a time.
    static let coverSizes = [64, 128, 256, 512, 1024]

    func coverArt(_ request: HTTPRequest) async throws -> HTTPResponse {
        let id = try Self.required("id", in: request)
        // The artwork store builds a file name from the id, so the id has to
        // be proven harmless here: exactly a SHA-256 in lowercase hex.
        guard Self.isArtworkID(id), let artwork else { throw EndpointFailure.notFound }

        let data: Data?
        if let requested = try Self.integer("size", in: request, default: nil, range: 1...100_000) {
            let size = Self.coverSizes.first { $0 >= requested } ?? Self.coverSizes.last ?? 1024
            data = try await artwork.thumbnail(for: id, maxPixelSize: size)
        } else {
            data = try await artwork.full(for: id)
        }
        guard let data, let contentType = MediaType.image(sniffing: data) else {
            throw EndpointFailure.notFound
        }
        return HTTPResponse(status: .ok, contentType: contentType, body: data)
    }

    static func isArtworkID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

extension MediaType {
    /// The type of an image from its first bytes, or nil for anything that is
    /// not an image the app would have stored. The bytes came from a tag in
    /// someone's music file; their type is checked, not assumed.
    static func image(sniffing data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if head.count >= 12, head[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46]),
           head[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return nil
    }
}
