import Foundation
import CryptoKit
import Security

/// The certificate the server presents, made on this Mac for this Mac.
///
/// There is no certificate authority to ask. The server lives on a home
/// network under a name like `studio-mac.local`, which no authority will
/// vouch for, and the plan rules out anything that needs one. So the Mac
/// signs its own certificate, and a device trusts it by **pinning**: at
/// pairing the device learns the certificate's fingerprint, and from then on
/// accepts that exact certificate and no other. The usual questions a
/// certificate answers (who issued it, what name it is for, is it in date)
/// are not what the device checks. It checks that the bytes are the ones it
/// was shown.
///
/// Apple's frameworks can generate a key and sign with it but have no public
/// way to build a certificate, and adding a dependency for that is what
/// `docs/server-ios-recon.md` decided against. This file is therefore a small
/// DER encoder for exactly one shape of X.509 certificate: version 3, a P-256
/// key, signed with ECDSA and SHA-256. It cannot produce anything else.
public struct SelfSignedCertificate: Sendable, Equatable {

    /// The certificate in DER, as it goes on the wire in a TLS handshake.
    public let der: Data

    /// SHA-256 of the DER bytes, in lowercase hex. This is what a device is
    /// shown at pairing and compares against ever after.
    public var fingerprint: String { Self.fingerprint(of: der) }

    public static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public enum CertificateError: Error {
        /// The key is not a P-256 private key this can sign with.
        case unsupportedKey
        case signingFailed
        /// The bytes produced were not accepted as a certificate. This is a
        /// bug in the encoder, caught here and not in a client's handshake.
        case malformed
    }

    /// Ten years. A pinned certificate is trusted for being the one that was
    /// shown, not for being in date, and one that expired would silently
    /// unpair every device. Long enough to outlast the pairing.
    ///
    /// This is longer than the 825 days Apple's TLS server policy allows, so
    /// the system's default evaluation rejects the certificate, for that
    /// reason alone. That is expected and harmless: a Cadence client never
    /// asks the system whether to trust the server. It compares the
    /// fingerprint and decides for itself. A client that did rely on default
    /// evaluation would be refusing to pin, which is the bug.
    public static let defaultLifetime: TimeInterval = 10 * 365 * 24 * 60 * 60

    /// Builds and signs a certificate for `privateKey`.
    ///
    /// - Parameters:
    ///   - commonName: A label for people reading the certificate. Nothing
    ///     verifies it, so it must not be anything private.
    ///   - privateKey: A P-256 private key. It signs the certificate and is
    ///     not copied or exported.
    ///   - serial: Sixteen bytes, random by default.
    public static func make(
        commonName: String, privateKey: SecKey,
        notBefore: Date = Date().addingTimeInterval(-24 * 60 * 60),
        lifetime: TimeInterval = defaultLifetime, serial: Data? = nil
    ) throws -> SelfSignedCertificate {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              // An uncompressed P-256 point: 0x04, then two 32-byte numbers.
              point.count == 65, point.first == 0x04,
              SecKeyIsAlgorithmSupported(privateKey, .sign, .ecdsaSignatureMessageX962SHA256)
        else { throw CertificateError.unsupportedKey }

        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid(OID.commonName), DER.utf8String(commonName)])]),
        ])
        let signatureAlgorithm = DER.sequence([DER.oid(OID.ecdsaWithSHA256)])

        let tbs = DER.sequence([
            DER.explicit(0, DER.integer([2])),                       // version 3
            DER.integer(serialBytes(serial)),
            signatureAlgorithm,
            name,                                                    // issuer
            DER.sequence([DER.time(notBefore), DER.time(notBefore.addingTimeInterval(lifetime))]),
            name,                                                    // subject: itself
            DER.sequence([
                DER.sequence([DER.oid(OID.ecPublicKey), DER.oid(OID.prime256v1)]),
                DER.bitString(point),
            ]),
            DER.explicit(3, DER.sequence([
                // Not a certificate authority: it can vouch for nothing else.
                DER.sequence([DER.oid(OID.basicConstraints), DER.boolean(true),
                              DER.octetString(DER.sequence([]))]),
                // Usable for signing a handshake, and only as a TLS server.
                DER.sequence([DER.oid(OID.keyUsage), DER.boolean(true),
                              DER.octetString(DER.tagged(0x03, [0x07, 0x80]))]),
                DER.sequence([DER.oid(OID.extendedKeyUsage),
                              DER.octetString(DER.sequence([DER.oid(OID.serverAuth)]))]),
            ])),
        ])

        var error: Unmanaged<CFError>?
        // The X9.62 form is already the DER structure a certificate carries.
        guard let signature = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error) as Data?
        else { throw CertificateError.signingFailed }

        let der = Data(DER.sequence([tbs, signatureAlgorithm, DER.bitString(signature)]))
        // Checked by the system's own parser before anyone relies on it.
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw CertificateError.malformed
        }
        return SelfSignedCertificate(der: der)
    }

    /// A new P-256 private key held in memory only. The app keeps its key in
    /// the keychain instead; this is for tests and for code that needs a key
    /// without one.
    public static func makeEphemeralKey() throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw CertificateError.unsupportedKey
        }
        return key
    }

    /// Sixteen bytes that read as a positive number of fixed length: the top
    /// bit clear so it is not negative, the next set so it has no leading
    /// zero to strip.
    private static func serialBytes(_ given: Data?) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        if let given, given.count == 16 {
            bytes = [UInt8](given)
        } else {
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        }
        bytes[0] = (bytes[0] & 0x7F) | 0x40
        return bytes
    }
}

// MARK: - Object identifiers

/// Each already in its DER content form.
private enum OID {
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]                                 // 2.5.4.3
    static let ecdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]  // 1.2.840.10045.4.3.2
    static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]        // 1.2.840.10045.2.1
    static let prime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]   // 1.2.840.10045.3.1.7
    static let basicConstraints: [UInt8] = [0x55, 0x1D, 0x13]                           // 2.5.29.19
    static let keyUsage: [UInt8] = [0x55, 0x1D, 0x0F]                                   // 2.5.29.15
    static let extendedKeyUsage: [UInt8] = [0x55, 0x1D, 0x25]                           // 2.5.29.37
    static let serverAuth: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]   // 1.3.6.1.5.5.7.3.1
}

// MARK: - DER

/// Just enough of DER to write the certificate above. It only encodes, and
/// only values this file constructs: nothing here ever reads bytes from the
/// network.
enum DER {
    static func tagged(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    /// Short form under 128; otherwise a count of length bytes, then the
    /// length, most significant byte first.
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tagged(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tagged(0x31, items.flatMap { $0 }) }
    static func oid(_ content: [UInt8]) -> [UInt8] { tagged(0x06, content) }
    static func boolean(_ value: Bool) -> [UInt8] { tagged(0x01, [value ? 0xFF : 0x00]) }
    static func utf8String(_ text: String) -> [UInt8] { tagged(0x0C, Array(text.utf8)) }
    static func octetString(_ content: [UInt8]) -> [UInt8] { tagged(0x04, content) }

    /// A context-specific, constructed wrapper: `[n] EXPLICIT`.
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        tagged(0xA0 | number, content)
    }

    /// With no unused bits, which is true of everything encoded here.
    static func bitString(_ content: Data) -> [UInt8] { tagged(0x03, [0x00] + [UInt8](content)) }

    /// A non-negative integer from its big-endian bytes, in the minimal form
    /// DER requires: no needless leading zeroes, and a zero in front when the
    /// top bit would otherwise read as a minus sign.
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var content = Array(bytes.drop { $0 == 0 })
        if content.isEmpty { content = [0] }
        if content[0] & 0x80 != 0 { content.insert(0, at: 0) }
        return tagged(0x02, content)
    }

    /// `UTCTime` through 2049 and `GeneralizedTime` from 2050, as RFC 5280
    /// requires. A ten-year certificate made in the 2040s crosses that line.
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year ?? 2000
        let rest = String(format: "%02d%02d%02d%02d%02dZ", parts.month ?? 1, parts.day ?? 1,
                          parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        if year < 2050 {
            return tagged(0x17, Array((String(format: "%02d", year % 100) + rest).utf8))
        }
        return tagged(0x18, Array((String(format: "%04d", year) + rest).utf8))
    }
}
