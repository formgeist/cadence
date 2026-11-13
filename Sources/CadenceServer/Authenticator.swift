import Foundation
import CryptoKit

/// Decides whether an API key belongs to a paired device.
///
/// The server asks; it never holds keys itself. Phase 3 puts the real answer
/// behind this: one key per paired device, stored hashed, revocable.
public protocol Authenticator: Sendable {
    func isValid(apiKey: String) async -> Bool
}

/// One key, fixed for the life of the process. This stands in for pairing
/// until pairing exists, and backs the tests.
///
/// The key is supplied by whoever starts the server and is never written
/// down: not in the repository, not in a log, and not here either. Only its
/// digest is kept, the same shape the paired-device store will have.
public struct FixedKeyAuthenticator: Authenticator {
    private let digest: SHA256.Digest

    public init(key: String) {
        digest = SHA256.hash(data: Data(key.utf8))
    }

    public func isValid(apiKey: String) async -> Bool {
        // Comparing digests, which CryptoKit does in constant time, so how
        // long a refusal takes says nothing about how close the guess was.
        SHA256.hash(data: Data(apiKey.utf8)) == digest
    }
}
