import Foundation
import CryptoKit

/// The last answer the server gave to each browse request, kept as files, so
/// the library shows at once on launch and stays browsable while the Mac is
/// asleep.
///
/// As `docs/server-ios-recon.md` chose: one file per request in the Caches
/// directory, holding the response exactly as it arrived, keyed by endpoint
/// and parameters. No database, so GRDB stays out of the phone. Search is
/// not cached: it goes to the server, where the full-text index is.
///
/// **Nothing secret is stored.** The key is never part of a cache key or a
/// file. Responses hold the library's names and ids, which is what the cache
/// is for.
///
/// Give each paired Mac a folder of its own, so two libraries never mix, and
/// call `removeAll()` when the device is unpaired.
public final class RemoteMetadataCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The stored answer to a request, or nil.
    func data(for endpoint: String, _ parameters: [URLQueryItem]) -> Data? {
        try? Data(contentsOf: file(endpoint, parameters))
    }

    /// Replaces the stored answer. Written atomically, so a reader sees the
    /// old answer or the new one, never part of one. A failure to write is
    /// ignored: the cache is a convenience, and the next answer tries again.
    func store(_ data: Data, for endpoint: String, _ parameters: [URLQueryItem]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(endpoint, parameters), options: [.atomic])
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A digest of the endpoint and its parameters in a fixed order, so the
    /// same request is the same file however its parameters were listed.
    private func file(_ endpoint: String, _ parameters: [URLQueryItem]) -> URL {
        let canonical = ([endpoint] + parameters
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted())
            .joined(separator: "\u{1F}")
        let name = SHA256.hash(data: Data(canonical.utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
}

/// Where a browse request is answered from.
public enum RemoteReadSource: Sendable, Equatable {
    /// Ask the Mac, and keep its answer in the cache when there is one.
    case network
    /// The cached answer, without asking the Mac. Throws
    /// `RemoteError.notCached` when there is none.
    case cache
}
