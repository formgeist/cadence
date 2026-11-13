import Testing
import Foundation
import CryptoKit
import Security
@testable import CadenceServer

@Suite("Self-signed certificate")
struct SelfSignedCertificateTests {

    private func make(
        name: String = "Cadence on Studio Mac", notBefore: Date = Date(timeIntervalSince1970: 1_800_000_000),
        lifetime: TimeInterval = SelfSignedCertificate.defaultLifetime
    ) throws -> (certificate: SelfSignedCertificate, key: SecKey, parsed: SecCertificate) {
        let key = try SelfSignedCertificate.makeEphemeralKey()
        let certificate = try SelfSignedCertificate.make(
            commonName: name, privateKey: key, notBefore: notBefore, lifetime: lifetime)
        let parsed = try #require(SecCertificateCreateWithData(nil, certificate.der as CFData))
        return (certificate, key, parsed)
    }

    // MARK: What the system makes of it

    @Test("The system's own parser accepts it and reads back the name")
    func parses() throws {
        let made = try make(name: "Cadence on Studio Mac")
        #expect(SecCertificateCopySubjectSummary(made.parsed) as String? == "Cadence on Studio Mac")
    }

    @Test("It carries the public half of the key it was made for")
    func publicKey() throws {
        let made = try make()
        let inCertificate = try #require(SecCertificateCopyKey(made.parsed))
        let expected = try #require(SecKeyCopyPublicKey(made.key))
        #expect(SecKeyCopyExternalRepresentation(inCertificate, nil) as Data?
                == SecKeyCopyExternalRepresentation(expected, nil) as Data?)
    }

    /// Evaluates `certificate` with itself as the only anchor.
    private func evaluate(
        _ certificate: SecCertificate, policy: SecPolicy
    ) throws -> (trusted: Bool, error: String) {
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess)
        let evaluated = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(evaluated, [certificate] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(evaluated, true) == errSecSuccess)
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(evaluated, &error)
        return (trusted, error.map { String(describing: $0) } ?? "")
    }

    /// The real test of the encoder. With a lifetime inside Apple's limit for
    /// TLS server certificates, the system's strictest evaluation passes it:
    /// the signature, the dates, the key usage and the extensions are all as
    /// a TLS server's should be. No host name is checked, because a device
    /// pins the certificate and does not match a name.
    @Test("With a short lifetime, it passes the system's TLS server evaluation in full")
    func trustEvaluation() throws {
        let made = try make(notBefore: Date().addingTimeInterval(-3600),
                            lifetime: 800 * 86_400)
        let result = try evaluate(made.parsed, policy: SecPolicyCreateSSL(true, nil))
        #expect(result.trusted, "\(result.error)")
    }

    /// The default lifetime is ten years, on purpose: see `defaultLifetime`.
    /// That is longer than the 825 days Apple's TLS policy allows, and the
    /// system says so. This pins down that the lifetime is the *only* thing
    /// it objects to, and that the certificate is sound by the general X.509
    /// rules. A device does not run this policy: it compares the fingerprint.
    @Test("At ten years, the lifetime is the only thing the TLS policy objects to")
    func tenYearLifetime() throws {
        let made = try make(notBefore: Date().addingTimeInterval(-3600))
        let strict = try evaluate(made.parsed, policy: SecPolicyCreateSSL(true, nil))
        #expect(!strict.trusted)
        #expect(strict.error.contains("exceeds maximum temporal validity period"))
        #expect(!strict.error.contains("signature"))
        #expect(!strict.error.contains("extension"))
        #expect(!strict.error.contains("key usage"))

        let general = try evaluate(made.parsed, policy: SecPolicyCreateBasicX509())
        #expect(general.trusted, "\(general.error)")
    }

    @Test("Without being pinned, nothing trusts it")
    func untrustedByDefault() throws {
        let made = try make(notBefore: Date().addingTimeInterval(-3600))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(
            made.parsed, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess)
        #expect(!SecTrustEvaluateWithError(try #require(trust), nil))
    }

    @Test("A certificate pinned as anchor does not vouch for a different one")
    func anchorDoesNotCoverOthers() throws {
        let mine = try make(notBefore: Date().addingTimeInterval(-3600))
        let impostor = try make(notBefore: Date().addingTimeInterval(-3600))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(
            impostor.parsed, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess)
        let evaluated = try #require(trust)
        SecTrustSetAnchorCertificates(evaluated, [mine.parsed] as CFArray)
        SecTrustSetAnchorCertificatesOnly(evaluated, true)
        #expect(!SecTrustEvaluateWithError(evaluated, nil))
    }

    @Test("The signature verifies with the key, and not once a byte has changed")
    func signature() throws {
        let made = try make()
        let (tbs, signature) = try Self.split(made.certificate.der)
        let publicKey = try #require(SecKeyCopyPublicKey(made.key))
        #expect(SecKeyVerifySignature(
            publicKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, signature as CFData, nil))

        var tampered = tbs
        tampered[tampered.count / 2] ^= 0x01
        #expect(!SecKeyVerifySignature(
            publicKey, .ecdsaSignatureMessageX962SHA256, tampered as CFData,
            signature as CFData, nil))
    }

    // MARK: Fingerprint

    @Test("The fingerprint is the SHA-256 of the certificate, in lowercase hex")
    func fingerprint() throws {
        let made = try make()
        let fingerprint = made.certificate.fingerprint
        #expect(fingerprint.count == 64)
        #expect(fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(fingerprint == SHA256.hash(data: made.certificate.der)
            .map { String(format: "%02x", $0) }.joined())
        #expect(SelfSignedCertificate.fingerprint(of: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Two certificates never share a fingerprint, even for one key and name")
    func distinct() throws {
        let key = try SelfSignedCertificate.makeEphemeralKey()
        let first = try SelfSignedCertificate.make(commonName: "Cadence", privateKey: key)
        let second = try SelfSignedCertificate.make(commonName: "Cadence", privateKey: key)
        #expect(first.fingerprint != second.fingerprint)
    }

    // MARK: Contents

    @Test("It is valid from the start date for the lifetime asked")
    func validity() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z
        let made = try make(notBefore: start, lifetime: 86_400)
        let der = [UInt8](made.certificate.der)
        #expect(Self.contains(der, Array("270115080000Z".utf8)))
        #expect(Self.contains(der, Array("270116080000Z".utf8)))
    }

    @Test("A date from 2050 on is written with a four-digit year")
    func generalizedTime() {
        // 2049-12-31T23:59:59Z and one second later.
        #expect(DER.time(Date(timeIntervalSince1970: 2_524_607_999))
                == [0x17, 13] + Array("491231235959Z".utf8))
        #expect(DER.time(Date(timeIntervalSince1970: 2_524_608_000))
                == [0x18, 15] + Array("20500101000000Z".utf8))
    }

    @Test("A certificate that runs past 2050 still parses and evaluates")
    func longLived() throws {
        let made = try make(notBefore: Date().addingTimeInterval(-3600),
                            lifetime: 40 * 365 * 86_400)
        let result = try evaluate(made.parsed, policy: SecPolicyCreateBasicX509())
        #expect(result.trusted, "\(result.error)")
    }

    @Test("The serial number is positive, sixteen bytes and different each time")
    func serial() throws {
        var serials: Set<Data> = []
        for _ in 0..<50 {
            let made = try make()
            let serial = try #require(SecCertificateCopySerialNumberData(made.parsed, nil) as Data?)
            #expect(serial.count == 16)
            #expect(serial[0] & 0x80 == 0)
            #expect(serial[0] & 0x40 != 0)
            serials.insert(serial)
        }
        #expect(serials.count == 50)
    }

    @Test("Names of any length and script survive", arguments: [
        "C", "Cadence on Søren's Mac", "Cadence 🎧 音楽",
        String(repeating: "long name ", count: 30),
    ])
    func names(name: String) throws {
        let made = try make(name: name)
        #expect(SecCertificateCopySubjectSummary(made.parsed) as String? == name)
    }

    @Test("A key that is not P-256 is refused")
    func wrongKey() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 384,
        ]
        let p384 = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        #expect(throws: SelfSignedCertificate.CertificateError.self) {
            _ = try SelfSignedCertificate.make(commonName: "Cadence", privateKey: p384)
        }
        let publicOnly = try #require(SecKeyCopyPublicKey(try SelfSignedCertificate.makeEphemeralKey()))
        #expect(throws: SelfSignedCertificate.CertificateError.self) {
            _ = try SelfSignedCertificate.make(commonName: "Cadence", privateKey: publicOnly)
        }
    }

    // MARK: DER

    @Test("Lengths use the short form under 128 and the long form from there")
    func lengths() {
        #expect(DER.length(0) == [0x00])
        #expect(DER.length(127) == [0x7F])
        #expect(DER.length(128) == [0x81, 0x80])
        #expect(DER.length(255) == [0x81, 0xFF])
        #expect(DER.length(256) == [0x82, 0x01, 0x00])
        #expect(DER.length(65_535) == [0x82, 0xFF, 0xFF])
        #expect(DER.length(65_536) == [0x83, 0x01, 0x00, 0x00])
    }

    @Test("Integers are minimal and never read as negative")
    func integers() {
        #expect(DER.integer([0]) == [0x02, 0x01, 0x00])
        #expect(DER.integer([]) == [0x02, 0x01, 0x00])
        #expect(DER.integer([2]) == [0x02, 0x01, 0x02])
        #expect(DER.integer([0x7F]) == [0x02, 0x01, 0x7F])
        #expect(DER.integer([0x80]) == [0x02, 0x02, 0x00, 0x80])
        #expect(DER.integer([0x00, 0x00, 0x01]) == [0x02, 0x01, 0x01])
        #expect(DER.integer([0x00, 0xFF]) == [0x02, 0x02, 0x00, 0xFF])
    }

    // MARK: Helpers

    /// The signed part of a certificate and its signature, taken apart by
    /// hand: outer SEQUENCE { tbs SEQUENCE, algorithm SEQUENCE, BIT STRING }.
    private static func split(_ der: Data) throws -> (tbs: Data, signature: Data) {
        let bytes = [UInt8](der)
        var index = 0
        func header() throws -> (tag: UInt8, length: Int) {
            let tag = bytes[index]
            index += 1
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                length = 0
                for _ in 0..<count {
                    length = length << 8 | Int(bytes[index])
                    index += 1
                }
            }
            return (tag, length)
        }
        _ = try header()                       // outer SEQUENCE
        let tbsStart = index
        let tbs = try header()
        let tbsEnd = index + tbs.length
        index = tbsEnd
        let algorithm = try header()
        index += algorithm.length
        let bits = try header()
        #expect(bits.tag == 0x03)
        #expect(bytes[index] == 0x00)          // no unused bits
        return (Data(bytes[tbsStart..<tbsEnd]),
                Data(bytes[(index + 1)..<(index + bits.length)]))
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains {
            haystack[$0..<($0 + needle.count)].elementsEqual(needle)
        }
    }
}
