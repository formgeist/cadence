import Foundation

/// What the Mac's QR code says: where the server is, how to know it is the
/// right one, and the one-time token that pairs with it.
///
/// It is written as a URL so that it scans as a link the iOS app can claim:
///
///     cadence://pair?v=1&host=studio-mac.local&port=4533&fp=…&token=…&name=Studio%20Mac
///
/// The Mac writes it and the phone reads it, so both sides share this one
/// type. The reading side is the careful one. A QR code is input from the
/// outside world: anyone can print one, and a camera will scan it. `init(url:)`
/// accepts exactly what `url` produces and refuses everything else.
///
/// **What the fingerprint is for.** It is the SHA-256 of the Mac's
/// certificate. The phone connects to `host`, checks that the certificate it
/// is shown has this fingerprint, and only then sends the token. A device
/// answering in the Mac's place cannot produce that certificate, so it never
/// sees the token. This is why pairing by QR code needs no confirmation.
public struct PairingPayload: Sendable, Equatable {

    public static let version = 1

    /// A host name such as `studio-mac.local`, or an IP address.
    public var host: String
    public var port: UInt16
    /// SHA-256 of the server's certificate: 64 lowercase hex characters.
    public var fingerprint: String
    /// The one-time pairing token. Opaque to the phone.
    public var token: String
    /// The Mac's name, to show while pairing. Display only.
    public var name: String

    public enum ParseError: Error, Equatable {
        /// Not a Cadence pairing code at all.
        case notAPairingCode
        /// A pairing code from a newer Cadence than this one understands.
        /// Distinct from the rest so the app can say "update needed".
        case unsupportedVersion(Int)
        /// A pairing code with a part missing or not as it should be.
        case malformed(String)
    }

    public init(host: String, port: UInt16, fingerprint: String, token: String, name: String) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.token = token
        self.name = name
    }

    /// The text to put in the QR code.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "cadence"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "fp", value: fingerprint),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "name", value: name),
        ]
        return components.url
    }

    /// Reads a scanned code. Throws for anything that is not exactly a
    /// pairing code this version understands.
    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "cadence", components.host == "pair",
              components.path.isEmpty, components.user == nil, components.port == nil,
              components.fragment == nil, let items = components.queryItems else {
            throw ParseError.notAPairingCode
        }

        // Each field once. A code that says two things is not one to guess at.
        var fields: [String: String] = [:]
        for item in items {
            guard let value = item.value, fields[item.name] == nil else {
                throw ParseError.malformed(item.name)
            }
            fields[item.name] = value
        }

        guard let versionText = fields["v"], Self.isDigits(versionText, max: 4),
              let version = Int(versionText) else { throw ParseError.malformed("v") }
        guard version == Self.version else { throw ParseError.unsupportedVersion(version) }

        // Known fields only: a v1 code with extra parts is not a v1 code.
        guard Set(fields.keys) == ["v", "host", "port", "fp", "token", "name"] else {
            throw ParseError.malformed("fields")
        }

        guard let host = fields["host"], Self.isHost(host) else { throw ParseError.malformed("host") }
        guard let portText = fields["port"], Self.isDigits(portText, max: 5),
              let port = UInt16(portText), port > 0 else { throw ParseError.malformed("port") }
        guard let fingerprint = fields["fp"], fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        else { throw ParseError.malformed("fp") }
        guard let token = fields["token"], (16...128).contains(token.utf8.count),
              token.utf8.allSatisfy(Self.isTokenByte) else { throw ParseError.malformed("token") }
        guard let name = fields["name"], name.count <= 64,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ParseError.malformed("name") }

        self.init(host: host, port: port, fingerprint: fingerprint, token: token, name: name)
    }

    // MARK: - Checks

    private static func isDigits(_ text: String, max: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= max && text.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    /// Letters, digits, `-` and `_`: the URL-safe base64 alphabet.
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            || byte == 45 || byte == 95
    }

    /// A DNS name or an IP address: letters, digits, dots, hyphens, and the
    /// colons of an IPv6 address. Nothing that could turn the host into a
    /// path, a port, credentials or a different host once it is put in a URL.
    private static func isHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.first != ".", host.first != "-" else { return false }
        return host.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || byte == 46 || byte == 45 || byte == 58
        }
    }
}
