import Foundation
import CryptoKit
import Security

/// A `URLSession` that trusts exactly one certificate: the one whose
/// SHA-256 fingerprint the device learned at pairing.
///
/// The Mac's certificate is self-signed and lasts ten years, which no default
/// trust evaluation accepts. That is intended: the only way to reach the
/// server is to pin it, so a client that forgets to cannot connect at all.
///
/// The check is the leaf certificate's fingerprint and nothing else. Host
/// name, expiry and chain are deliberately not consulted: the fingerprint
/// already names one certificate, and the Mac's address changes with the
/// network it is on.
///
/// **One check per request.** Each request gets its own `PinCheck` as its
/// task delegate, so a refusal is known to belong to that request. A refused
/// challenge surfaces from `URLSession` as a plain cancellation, and this is
/// how it is told apart from one.
struct PinnedSession: Sendable {
    private let session: URLSession
    let fingerprint: String

    init(fingerprint: String, timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        // Requests carry the API key in their query, as the protocol has it.
        // Nothing is cached, so no copy of a URL with a key in it is kept.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        // A Mac that is asleep should fail now, so the app can say so, not
        // after the system has waited for a network that will not come.
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        // No session delegate: the server-trust challenge then goes to the
        // task delegate each request passes in.
        session = URLSession(configuration: configuration)
        self.fingerprint = fingerprint.lowercased()
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let check = PinCheck(fingerprint: fingerprint)
        do {
            let (data, response) = try await session.data(for: request, delegate: check)
            guard let http = response as? HTTPURLResponse else { throw RemoteError.invalidResponse }
            return (data, http)
        } catch {
            throw Self.map(error, check)
        }
    }

    /// Throws `RemoteError`, or `CancellationError`.
    ///
    /// Downloads to a temporary file that the caller must move or delete.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let check = PinCheck(fingerprint: fingerprint)
        do {
            let (file, response) = try await session.download(for: request, delegate: check)
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: file)
                throw RemoteError.invalidResponse
            }
            return (file, http)
        } catch {
            throw Self.map(error, check)
        }
    }

    /// A `RemoteError`, or `CancellationError` when the enclosing task was
    /// cancelled, which is how a skip stops a download.
    private static func map(_ error: any Error, _ check: PinCheck) -> any Error {
        if error is RemoteError || error is CancellationError { return error }
        if check.rejected { return RemoteError.untrustedServer }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return RemoteError.transport(urlError)
        }
        return RemoteError.unreachable
    }

    /// SHA-256 of a certificate's DER bytes, in lowercase hex: the same
    /// form the Mac shows and the pairing code carries.
    static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

private final class PinCheck: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let fingerprint: String
    private let lock = NSLock()
    private var didReject = false

    init(fingerprint: String) { self.fingerprint = fingerprint }

    var rejected: Bool { lock.withLock { didReject } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        else {
            // A client certificate, or anything else this client has no
            // answer to. The default declines it.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              PinnedSession.fingerprint(of: leaf) == fingerprint
        else {
            lock.withLock { didReject = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
