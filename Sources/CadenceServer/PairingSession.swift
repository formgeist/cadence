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
        /// Six digits, as text: a code may begin with zeroes.
        public let digits: String
        public let expiresAt: Date
    }

    public static let codeLength = 6

    private struct Active {
        var code: Code
        var digest: SHA256.Digest
        var attemptsLeft: Int
    }

    private let devices: PairedDeviceStore
    private let lifetime: TimeInterval
    private let maximumAttempts: Int
    private let now: @Sendable () -> Date
    private var active: Active?

    public init(devices: PairedDeviceStore, lifetime: TimeInterval = 300,
                maximumAttempts: Int = 5, now: @escaping @Sendable () -> Date = Date.init) {
        self.devices = devices
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
        let code = Code(digits: digits, expiresAt: now().addingTimeInterval(lifetime))
        active = Active(code: code, digest: SHA256.hash(data: Data(digits.utf8)),
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
        expireIfNeeded()
        guard var session = active else { return nil }

        // Digests, compared in constant time: how long a wrong guess takes
        // says nothing about how many digits were right.
        guard SHA256.hash(data: Data(code.utf8)) == session.digest else {
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
