import Foundation
import CadenceCore

/// Pairs this device with a Mac, from the code the Mac shows.
///
/// The order matters, and is the reason pairing by QR code needs no
/// confirmation step:
///
/// 1. Connect to the address in the code, and check the certificate against
///    the fingerprint in the code. A device answering in the Mac's place
///    cannot show that certificate, so it is refused here and never sees
///    the token.
/// 2. Ask which protocol version the server speaks, using the one endpoint
///    that needs no key. A mismatched server is refused before a key is made
///    for a device that could not use it.
/// 3. Trade the one-time token for this device's own key, with `POST /pair`.
public enum RemotePairing {

    /// - Parameter deviceName: How this device appears in the Mac's list of
    ///   paired devices, such as "Casper's iPhone".
    /// - Throws: `RemoteError`: `.untrustedServer` for a certificate that is
    ///   not the one in the code, `.pairingRefused` for a token that is
    ///   wrong, used or expired, or pairing that is not open on the Mac.
    public static func pair(
        _ payload: PairingPayload, deviceName: String, timeout: TimeInterval = 15
    ) async throws -> RemoteCredentials {
        let server = RemoteServer(host: payload.host, port: payload.port,
                                  fingerprint: payload.fingerprint, name: payload.name)
        let session = PinnedSession(fingerprint: payload.fingerprint, timeout: timeout)
        defer { session.invalidate() }
        guard let base = server.baseURL else { throw RemoteError.invalidResponse }

        // 1 and 2: the pin is checked on this request, before anything else.
        var extensions = URLComponents(url: base, resolvingAgainstBaseURL: false)
        extensions?.path = "/rest/getOpenSubsonicExtensions"
        extensions?.queryItems = [.init(name: "f", value: "json")]
        guard let extensionsURL = extensions?.url else { throw RemoteError.invalidResponse }
        let (envelope, envelopeResponse) = try await session.data(for: URLRequest(url: extensionsURL))
        let body = try RemoteLibraryClient.checked(envelopeResponse, envelope)
        guard body.cadenceProtocolVersion == RemoteLibraryClient.protocolVersion else {
            throw RemoteError.incompatibleServer(serverVersion: body.serverVersion ?? "unknown",
                                                 protocolVersion: body.cadenceProtocolVersion)
        }

        // 3.
        var request = URLRequest(url: base.appending(path: "pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(token: payload.token, name: deviceName))
        let (data, response) = try await session.data(for: request)

        switch response.statusCode {
        case 200:
            break
        // 403 is every refusal; 404 is a server with pairing switched off.
        case 403, 404:
            throw RemoteError.pairingRefused
        default:
            throw RemoteLibraryClient.failure(response, body: data)
        }
        guard let paired = try? JSONDecoder().decode(Response.self, from: data),
              !paired.apiKey.isEmpty
        else { throw RemoteError.invalidResponse }
        guard paired.cadenceProtocolVersion == RemoteLibraryClient.protocolVersion else {
            throw RemoteError.incompatibleServer(serverVersion: paired.serverVersion,
                                                 protocolVersion: paired.cadenceProtocolVersion)
        }
        return RemoteCredentials(server: server, apiKey: paired.apiKey, deviceID: paired.deviceId)
    }

    private struct Request: Encodable {
        var token: String
        var name: String
    }

    private struct Response: Decodable {
        var apiKey: String
        var deviceId: String
        var serverVersion: String
        var cadenceProtocolVersion: Int
    }
}
