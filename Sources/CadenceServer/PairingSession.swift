import Foundation
import CryptoKit

/// The one-time code that lets a new device pair with this Mac.
///
/// Pairing is the only way a device is ever added, and it is open only while
/// the user has asked for it: the Mac shows a code, and a device that sends
/// that code back is given a key. With no code showing, there is nothing to
/// guess at.
///
/// A code is six digits because a person has to type it. What makes six
/// digits safe is everything around them:
///
/// - **It works once.** A code that is used is gone, including when two
///   requests arrive with it at the same moment.
/// - **It expires** after five minutes.
/// - **It allows five attempts.** The fifth wrong one cancels the code, and
///   the user has to ask for another. A stranger on the network therefore
///   has five chances in a million per code the user chooses to show.
/// - **Every refusal looks the same.** Wrong, expired, used up and "no code
///   is showing" are one answer, so a refusal teaches nothing.
///
/// The price of the attempt limit is that someone on the network can spoil a
/// code by guessing five times. That costs the user a second try and gains
/// the stranger nothing.
public actor PairingSession {

    public struct Code: Sendable, Equatable {
        /// Six digits, as text: a code may begin with zeroes. For a person
        /// to type.
        public let digits: String
        /// 256 random bits, for the QR code. A device that scanned the QR
        /// code sends this, not the digits.
        public let token: String
        public let expiresAt: Date
    }

    public static let codeLength = 6

    private struct Active {
        var code: Code
        var digest: SHA256.Digest
        var tokenDigest: SHA256.Digest
        var attemptsLeft: Int
    }

    private let devices: PairedDeviceStore
    private let lifetime: TimeInterval
    private let maximumAttempts: Int
    private let now: @Sendable () -> Date
    private let allowsTypedCode: Bool
    private var active: Active?

    /// - Parameter allowsTypedCode: Whether the six digits alone can pair a
    ///   device. **Off by default, and it must stay off in the app for now.**
    ///   A device that scans the QR code has the Mac's certificate
    ///   fingerprint and cannot be fooled by an impostor; a device whose user
    ///   types six digits has nothing to check the server against, so an
    ///   impostor on the network could collect the digits and pair itself.
    ///   Typed codes need a confirmation step that does not exist yet.
    public init(devices: PairedDeviceStore, lifetime: TimeInterval = 300,
                maximumAttempts: Int = 5, allowsTypedCode: Bool = false,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.devices = devices
        self.allowsTypedCode = allowsTypedCode
        self.lifetime = lifetime
        self.maximumAttempts = maximumAttempts
        self.now = now
    }

    /// Opens pairing and returns the code to show. Any earlier code stops
    /// working: there is only ever one.
    public func begin() -> Code {
        var generator = SystemRandomNumberGenerator()
        // `Int.random(in:using:)` is uniform over the range, so no code is
        // likelier than another.
        let number = Int.random(in: 0..<1_000_000, using: &generator)
        let digits = String(repeating: "0", count: Self.codeLength - String(number).count)
            + String(number)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("The system random generator is unavailable.")
        }
        let token = PairedDeviceStore.base64URL(Data(bytes))
        let code = Code(digits: digits, token: token,
                        expiresAt: now().addingTimeInterval(lifetime))
        active = Active(code: code, digest: SHA256.hash(data: Data(digits.utf8)),
                        tokenDigest: SHA256.hash(data: Data(token.utf8)),
                        attemptsLeft: maximumAttempts)
        return code
    }

    /// Closes pairing. Called when the user dismisses the code.
    public func cancel() {
        active = nil
    }

    /// The code now showing, or nil when pairing is closed or the code has
    /// run out.
    public func current() -> Code? {
        expireIfNeeded()
        return active?.code
    }

    /// Pairs a device that presents the right code, and returns its key.
    /// Nil for every kind of failure, deliberately without saying which.
    public func redeem(
        code: String, deviceName: String
    ) async -> (device: PairedDevice, apiKey: String)? {
        // Refused outright, and not counted: with typed codes off, the
        // digits are not a way in at all, right or wrong.
        guard allowsTypedCode else { return nil }
        return await redeem(code, against: \.digest, deviceName: deviceName)
    }

    /// Pairs a device that presents the token from the QR code.
    public func redeem(
        token: String, deviceName: String
    ) async -> (device: PairedDevice, apiKey: String)? {
        await redeem(token, against: \.tokenDigest, deviceName: deviceName)
    }

    private func redeem(
        _ secret: String, against expected: KeyPath<Active, SHA256.Digest>, deviceName: String
    ) async -> (device: PairedDevice, apiKey: String)? {
        expireIfNeeded()
        guard var session = active else { return nil }

        // Digests, compared in constant time: how long a wrong guess takes
        // says nothing about how much of it was right.
        guard SHA256.hash(data: Data(secret.utf8)) == session[keyPath: expected] else {
            session.attemptsLeft -= 1
            active = session.attemptsLeft > 0 ? session : nil
            return nil
        }

        // Spent before anything is awaited. An actor lets other calls in
        // while it waits, and a second request carrying the same code must
        // find it already gone.
        active = nil
        return try? await devices.pair(named: deviceName)
    }

    private func expireIfNeeded() {
        if let session = active, now() >= session.code.expiresAt { active = nil }
    }
}
