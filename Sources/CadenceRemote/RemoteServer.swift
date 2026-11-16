import Foundation

/// A Mac running Cadence's library server, as a paired device knows it.
public struct RemoteServer: Sendable, Equatable, Codable {
    /// A host name such as `studio-mac.local`, or an IP address.
    public var host: String
    public var port: UInt16
    /// SHA-256 of the server's certificate, in lowercase hex. The only thing
    /// that decides whether a server is this one: a connection to a server
    /// whose certificate has any other fingerprint is refused before a byte
    /// of the request is sent.
    public var fingerprint: String
    /// The Mac's name, for display.
    public var name: String

    public init(host: String, port: UInt16, fingerprint: String, name: String) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.name = name
    }

    /// `https://host:port`, with an IPv6 address in brackets.
    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = Int(port)
        return components.url
    }
}

/// What pairing leaves a device with: the server, and its own key to it.
///
/// **The API key is a secret.** It is the whole of the device's access to the
/// library. The app keeps it in the keychain, never in preferences or a file,
/// and nothing in this module writes it anywhere or logs it.
public struct RemoteCredentials: Sendable, Equatable, Codable {
    public var server: RemoteServer
    public var apiKey: String
    /// This device's id on the server, as the Mac's paired-devices list
    /// shows it.
    public var deviceID: String

    public init(server: RemoteServer, apiKey: String, deviceID: String) {
        self.server = server
        self.apiKey = apiKey
        self.deviceID = deviceID
    }
}
