import Foundation
import CryptoKit

/// Decides which paired device an API key belongs to, if any.
///
/// The server asks; it never holds keys itself. `PairedDeviceStore` is the
/// real answer: one key per paired device, stored hashed, revocable.
public protocol Authenticator: Sendable {
    /// The device `apiKey` was issued to, or nil for a key that was never
    /// issued or has been revoked.
    ///
    /// It answers with the device and not just yes or no because what a
    /// request may do next depends on whose it is: limits are kept per
    /// device, and the Mac shows which devices are connected.
    func device(forAPIKey apiKey: String) async -> PairedDevice.ID?
}

/// One key, fixed for the life of the process. For the debug harness, the
/// benchmark and the tests, which have no pairing to go through.
///
/// The key is supplied by whoever starts the server and is never written
/// down: not in the repository, not in a log, and not here either. Only its
/// digest is kept, the same shape `PairedDeviceStore` has.
public struct FixedKeyAuthenticator: Authenticator {
    private let digest: SHA256.Digest
    /// The one device this key stands for.
    public let deviceID: PairedDevice.ID

    public init(key: String, deviceID: PairedDevice.ID = UUID()) {
        digest = SHA256.hash(data: Data(key.utf8))
        self.deviceID = deviceID
    }

    public func device(forAPIKey apiKey: String) async -> PairedDevice.ID? {
        // Comparing digests, which CryptoKit does in constant time, so how
        // long a refusal takes says nothing about how close the guess was.
        SHA256.hash(data: Data(apiKey.utf8)) == digest ? deviceID : nil
    }
}
