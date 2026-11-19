import Foundation
import CryptoKit

/// Short-lived permission to download one song, for a request the device
/// hands to the system to carry out in the background.
///
/// A background download is performed by the system, which keeps the request
/// it was given, query and all, outside the app until it is done. The API key
/// must not be in that request: it is the device's whole access, it does not
/// expire, and the system's copy is out of the app's hands. A download token
/// is what goes there instead. It is worth one song, to one device, for a few
/// hours:
///
/// - **Bound to the song and the device.** It is an HMAC over both and its
///   expiry, so it cannot be moved to another song, and it is refused once
///   the device is revoked.
/// - **Short-lived.** Six hours by default: enough for a queue the system
///   works through while the phone is locked, not enough to matter if a copy
///   lingers.
/// - **Accepted by `download` only.** Every other endpoint still needs the
///   key.
/// - **Stateless.** Nothing is stored per token. The secret is made at
///   launch and kept in memory, so quitting Cadence ends every token issued;
///   the app asks for new ones when it next runs.
///
/// Format: `v1.<device id>.<expiry, Unix seconds>.<MAC, base64url>`.
public struct DownloadTokens: Sendable {

    private let secret: SymmetricKey
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 6 * 60 * 60, secret: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.secret = secret
        self.lifetime = lifetime
    }

    /// A token for `songID`, sent by `device`, and when it stops working.
    public func issue(songID: String, device: PairedDevice.ID, now: Date) -> (token: String, expires: Date) {
        let expires = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + lifetime).rounded(.down))
        let expiry = String(Int(expires.timeIntervalSince1970))
        let deviceText = device.uuidString.lowercased()
        let mac = HMAC<SHA256>.authenticationCode(
            for: Self.message(deviceText, songID, expiry), using: secret)
        return ("v1.\(deviceText).\(expiry).\(Self.base64URL(Data(mac)))", expires)
    }

    /// The device a token was issued to, when it is genuine, unexpired and
    /// for `songID`; nil otherwise. Whether that device is still paired is
    /// the caller's to check.
    public func verify(_ token: String, songID: String, now: Date) -> PairedDevice.ID? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1",
              let device = UUID(uuidString: String(parts[1])),
              let expiry = Int(parts[2]), Double(expiry) > now.timeIntervalSince1970,
              let mac = Self.data(base64URL: String(parts[3]))
        else { return nil }
        // Compared in constant time by CryptoKit.
        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            mac, authenticating: Self.message(String(parts[1]), songID, String(parts[2])), using: secret)
        return valid ? device : nil
    }

    private static func message(_ device: String, _ songID: String, _ expiry: String) -> Data {
        // Separated by a byte no part can contain.
        Data("cadence-download-v1\u{0}\(device)\u{0}\(songID)\u{0}\(expiry)".utf8)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(base64URL text: String) -> Data? {
        guard text.count <= 64,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
