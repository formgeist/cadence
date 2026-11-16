import Foundation

/// Every way talking to the Mac can fail, in the terms the app shows them.
///
/// Transport errors, HTTP statuses and the protocol's own error codes all end
/// up here, so the app has one thing to switch over and never has to read a
/// `URLError` or a Subsonic error number.
public enum RemoteError: Error, Equatable, Sendable {
    /// The server's certificate is not the one this device paired with.
    /// Either something else is answering at the Mac's address, or the Mac's
    /// identity was reset. Nothing was sent to it.
    case untrustedServer
    /// The Mac no longer accepts this device's key: it was revoked, or the
    /// Mac forgot its paired devices. The fix is to pair again.
    case notPaired
    /// The pairing code was wrong, expired, already used, or pairing is not
    /// open on the Mac. The server does not say which, by design.
    case pairingRefused
    /// The Mac's server speaks a different version of Cadence's protocol.
    /// One of the two apps needs updating.
    case incompatibleServer(serverVersion: String, protocolVersion: Int?)
    /// What was asked for is not in the library, or no longer is.
    case notFound
    /// The Mac is refusing requests from this address for a while, or this
    /// device already has as many downloads open as it may.
    case busy(retryAfter: TimeInterval)
    /// This device has no network.
    case offline
    /// The network is up but the Mac did not answer: asleep, Cadence not
    /// running, sharing switched off, or on another network.
    case unreachable
    /// The server answered with a protocol error not covered above.
    case server(code: Int, message: String)
    /// The server answered with something that is not a well-formed reply.
    case invalidResponse
}

extension RemoteError {
    /// The error for a transport failure. A certificate the pinning check
    /// refused is caught before this, by `PinnedSession`.
    static func transport(_ error: URLError) -> RemoteError {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected:
            return .untrustedServer
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData,
             .cannotDecodeContentData, .zeroByteResource:
            return .invalidResponse
        default:
            // Timed out, connection refused, host not found, connection lost,
            // a TLS handshake that failed for another reason: all "the Mac
            // did not answer", which is what the listener can act on.
            return .unreachable
        }
    }
}
