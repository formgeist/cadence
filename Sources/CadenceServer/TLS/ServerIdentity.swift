import Foundation
import Security

/// The server's private key and certificate, as one thing TLS can present.
public struct ServerIdentity: @unchecked Sendable {
    // `SecIdentity` is an immutable reference the Security framework shares
    // freely between threads; it is only not marked `Sendable`.
    public let identity: SecIdentity
    public let certificate: SelfSignedCertificate

    /// What a device is shown at pairing and pins from then on.
    public var fingerprint: String { certificate.fingerprint }
}

/// Keeps the server's identity, making it the first time.
///
/// The two halves are kept in two places, each where it belongs:
///
/// - **The private key is in the keychain**, generated there and found by a
///   tag of its own. Nothing in Cadence reads its bytes: the TLS stack asks
///   the keychain to sign with it. A copy of the app's files contains no
///   part of it. It is created as not exportable, which macOS 26 enforces
///   and earlier systems do not; see `create`.
/// - **The certificate is in a file.** It is public: the server hands it to
///   anyone who connects. Keeping it in a file, and not beside the key in the
///   keychain, means it is found by path and not by a keychain search, which
///   matches certificates and identities by label loosely enough to return
///   the wrong one.
///
/// **The identity is made once and kept.** Every paired device has pinned
/// this certificate. Making a new one unpairs them all, so `loadOrCreate`
/// only creates when there is nothing usable to load, and `reset` exists as a
/// deliberate act: it is what "forget all devices and start again" means.
public struct ServerIdentityStore: Sendable {

    public enum IdentityError: Error, Equatable {
        /// With the keychain's own error code, for a log.
        case keyGenerationFailed(Int)
        case keychain(OSStatus)
    }

    /// The keychain is one shared file. Two identities being made at the
    /// same moment have been seen to make key generation fail, so everything
    /// here that touches it takes its turn.
    private static let keychainLock = NSLock()

    /// Where the certificate is kept.
    public let certificateURL: URL
    /// The keychain tag of the private key. Unique to this store, so that a
    /// lookup can only ever find this key.
    public let keyTag: String

    public init(certificateURL: URL, keyTag: String) {
        self.certificateURL = certificateURL
        self.keyTag = keyTag
    }

    /// The store the app uses.
    public static func standard() throws -> ServerIdentityStore {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("Cadence", isDirectory: true)
        return ServerIdentityStore(
            certificateURL: directory.appendingPathComponent("server-certificate.der"),
            keyTag: "com.formgeist.cadence.library-server.tls-key")
    }

    /// The stored identity, or a new one if there is none that works.
    public func loadOrCreate(commonName: String) throws -> ServerIdentity {
        try Self.keychainLock.withLock {
            if let existing = try loadUnlocked() { return existing }
            // Whatever is there is half an identity at best. Clear it first,
            // so a stale key can never be paired with a new certificate.
            resetUnlocked()
            return try create(commonName: commonName)
        }
    }

    /// The stored identity, or nil if there is not a complete one: no
    /// certificate file, no key, or a key that is not the certificate's.
    public func load() throws -> ServerIdentity? {
        try Self.keychainLock.withLock { try loadUnlocked() }
    }

    private func loadUnlocked() throws -> ServerIdentity? {
        guard let der = try? Data(contentsOf: certificateURL),
              let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let privateKey = try storedKey(),
              let ours = SecKeyCopyPublicKey(privateKey),
              let inCertificate = SecCertificateCopyKey(certificate),
              let a = SecKeyCopyExternalRepresentation(ours, nil) as Data?,
              let b = SecKeyCopyExternalRepresentation(inCertificate, nil) as Data?,
              a == b else { return nil }

        var identity: SecIdentity?
        // Finds the private key for this certificate's public key. It was
        // just confirmed above to be the one under our tag.
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw IdentityError.keychain(status)
        }
        return ServerIdentity(identity: identity, certificate: SelfSignedCertificate(der: der))
    }

    /// Removes the key and the certificate. Every paired device stops
    /// trusting the server, so this goes with unpairing them all.
    public func reset() {
        Self.keychainLock.withLock { resetUnlocked() }
    }

    private func resetUnlocked() {
        SecItemDelete(keyQuery as CFDictionary)
        try? FileManager.default.removeItem(at: certificateURL)
    }

    // MARK: - Pieces

    private var keyQuery: [CFString: Any] {
        [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: Data(keyTag.utf8),
        ]
    }

    private func storedKey() throws -> SecKey? {
        var query = keyQuery
        query[kSecReturnRef] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw IdentityError.keychain(status)
        }
        // Checked just above: the keychain returned a key.
        return (result as! SecKey)
    }

    private func create(commonName: String) throws -> ServerIdentity {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            // Stored, and not something that can be copied out again.
            //
            // "Not extractable" is asked for in both places it can be said,
            // and backed by "sensitive". macOS 26 honours it. macOS 15 does
            // not, for a key made this way in the login keychain: there the
            // app that made the key can still read it back out. The key is
            // still only in the keychain, never in a file, and the keychain
            // still asks the user before letting any other program use it.
            // What is lost on those systems is one layer: a Cadence that had
            // itself been taken over could export the key instead of only
            // signing with it. A test records which systems behave which way.
            kSecAttrIsPermanent: true,
            kSecAttrIsExtractable: false,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrIsExtractable: false,
                kSecAttrIsSensitive: true,
                kSecAttrApplicationTag: Data(keyTag.utf8),
                kSecAttrLabel: "Cadence Library Server",
            ] as [CFString: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
            throw IdentityError.keyGenerationFailed(code)
        }

        do {
            let certificate = try SelfSignedCertificate.make(
                commonName: commonName, privateKey: privateKey)
            try FileManager.default.createDirectory(
                at: certificateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try certificate.der.write(to: certificateURL, options: .atomic)
            guard let stored = try loadUnlocked() else {
                throw IdentityError.keychain(errSecItemNotFound)
            }
            return stored
        } catch {
            // Half an identity is worse than none.
            resetUnlocked()
            throw error
        }
    }
}
