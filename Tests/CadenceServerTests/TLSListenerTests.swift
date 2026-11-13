import Testing
import Foundation
import Security
import CadenceLibrary
@testable import CadenceServer

/// Trusts a server whose certificate has one exact fingerprint, and no other.
/// This is the check the iOS client will make.
private final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              SelfSignedCertificate.fingerprint(of: SecCertificateCopyData(leaf) as Data) == fingerprint
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// An identity with a key tag and a certificate file of its own, removed
/// afterwards. Nothing here touches the app's real identity.
private struct TemporaryIdentity {
    let store: ServerIdentityStore
    let directory: URL
    let identity: ServerIdentity

    init() throws {
        (store, directory) = Self.makeStore()
        identity = try store.loadOrCreate(commonName: "Cadence Test")
    }

    static func makeStore() -> (ServerIdentityStore, URL) {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-identity-\(id)")
        return (ServerIdentityStore(
            certificateURL: directory.appendingPathComponent("server-certificate.der"),
            keyTag: "com.formgeist.cadence.tests.\(id)"), directory)
    }

    func remove() {
        store.reset()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Server identity", .serialized)
struct ServerIdentityTests {

    @Test("An identity is made once and found again")
    func persists() throws {
        let (store, directory) = TemporaryIdentity.makeStore()
        defer { store.reset(); try? FileManager.default.removeItem(at: directory) }

        #expect(try store.load() == nil)
        let made = try store.loadOrCreate(commonName: "Cadence Test")
        #expect(made.fingerprint.count == 64)

        // Asking again gives the same certificate, not a new one: devices
        // that pinned it must go on trusting it.
        let again = try store.loadOrCreate(commonName: "Other Name")
        #expect(again.fingerprint == made.fingerprint)
        #expect(try store.load()?.fingerprint == made.fingerprint)
    }

    @Test("Resetting removes it, and the next one is different")
    func reset() throws {
        let (store, directory) = TemporaryIdentity.makeStore()
        defer { store.reset(); try? FileManager.default.removeItem(at: directory) }

        let first = try store.loadOrCreate(commonName: "Cadence Test")
        store.reset()
        #expect(try store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.certificateURL.path))

        let second = try store.loadOrCreate(commonName: "Cadence Test")
        #expect(second.fingerprint != first.fingerprint)
    }

    @Test("Two stores are two identities, and neither finds the other's")
    func separateStores() throws {
        let one = try TemporaryIdentity()
        defer { one.remove() }
        let two = try TemporaryIdentity()
        defer { two.remove() }
        #expect(one.identity.fingerprint != two.identity.fingerprint)
        #expect(try one.store.load()?.fingerprint == one.identity.fingerprint)
        #expect(try two.store.load()?.fingerprint == two.identity.fingerprint)
    }

    @Test("The private key cannot be copied out of the keychain")
    func keyNotExtractable() throws {
        let temporary = try TemporaryIdentity()
        defer { temporary.remove() }
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(temporary.identity.identity, &key) == errSecSuccess)
        var error: Unmanaged<CFError>?
        #expect(SecKeyCopyExternalRepresentation(try #require(key), &error) == nil)
    }

    @Test("The certificate file holds the certificate and nothing of the key")
    func certificateFile() throws {
        let temporary = try TemporaryIdentity()
        defer { temporary.remove() }
        let onDisk = try Data(contentsOf: temporary.store.certificateURL)
        #expect(onDisk == temporary.identity.certificate.der)
        let files = try FileManager.default.contentsOfDirectory(atPath: temporary.directory.path)
        #expect(files == ["server-certificate.der"])
    }

    /// A certificate whose key is gone, or a file that is not a certificate,
    /// is not an identity. A new one replaces it instead of failing forever.
    @Test("A broken identity is replaced, not loaded")
    func brokenIsReplaced() throws {
        let temporary = try TemporaryIdentity()
        defer { temporary.remove() }
        let original = temporary.identity.fingerprint

        // The certificate swapped for one that belongs to a different key.
        let stranger = try SelfSignedCertificate.make(
            commonName: "Stranger", privateKey: try SelfSignedCertificate.makeEphemeralKey())
        try stranger.der.write(to: temporary.store.certificateURL)
        #expect(try temporary.store.load() == nil)
        let replaced = try temporary.store.loadOrCreate(commonName: "Cadence Test")
        #expect(replaced.fingerprint != stranger.fingerprint)
        #expect(replaced.fingerprint != original)

        // The file overwritten with something that is not a certificate.
        try Data("not a certificate".utf8).write(to: temporary.store.certificateURL)
        #expect(try temporary.store.load() == nil)
        #expect(try temporary.store.loadOrCreate(commonName: "Cadence Test").fingerprint.count == 64)
    }
}

@Suite("TLS listener", .serialized)
struct TLSListenerTests {

    /// A TLS server over an empty library, for the length of `body`.
    private func withServer<T>(
        _ body: (_ base: URL, _ identity: ServerIdentity) async throws -> T
    ) async throws -> T {
        let temporary = try TemporaryIdentity()
        defer { temporary.remove() }
        let server = try await TestLibrary().server()
        let listener = try HTTPListener.tls(identity: temporary.identity, loopbackOnly: true) {
            await server.respond(to: $0)
        }
        let port = try await listener.start()
        defer { listener.stop() }
        return try await body(try #require(URL(string: "https://127.0.0.1:\(port)")),
                              temporary.identity)
    }

    private func session(pinning fingerprint: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration,
                          delegate: PinningDelegate(fingerprint: fingerprint), delegateQueue: nil)
    }

    private func pingURL(_ base: URL) throws -> URL {
        var components = try #require(URLComponents(
            url: base.appendingPathComponent("rest/ping"), resolvingAgainstBaseURL: false))
        components.queryItems = [.init(name: "apiKey", value: TestLibrary.key)]
        return try #require(components.url)
    }

    @Test("A client that pins the server's fingerprint connects over TLS")
    func pinnedClientConnects() async throws {
        try await withServer { base, identity in
            let (data, response) = try await session(pinning: identity.fingerprint)
                .data(from: try pingURL(base))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect((json?["subsonic-response"] as? [String: Any])?["status"] as? String == "ok")
        }
    }

    @Test("A client that pins a different fingerprint refuses the server")
    func wrongFingerprintRejected() async throws {
        try await withServer { base, _ in
            let other = try SelfSignedCertificate.make(
                commonName: "Impostor", privateKey: try SelfSignedCertificate.makeEphemeralKey())
            await #expect(throws: URLError.self) {
                _ = try await session(pinning: other.fingerprint).data(from: try pingURL(base))
            }
        }
    }

    /// The ten-year certificate is not one default evaluation accepts. A
    /// client must pin; this is what happens to one that does not.
    @Test("A client that does not pin refuses the server")
    func unpinnedClientRejected() async throws {
        try await withServer { base, _ in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            await #expect(throws: URLError.self) {
                _ = try await URLSession(configuration: configuration).data(from: try pingURL(base))
            }
        }
    }

    @Test("Plain HTTP to the TLS port gets nothing")
    func plainHTTPRefused() async throws {
        try await withServer { base, _ in
            var components = try #require(URLComponents(
                url: try pingURL(base), resolvingAgainstBaseURL: false))
            components.scheme = "http"
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            await #expect(throws: URLError.self) {
                _ = try await URLSession(configuration: configuration)
                    .data(from: try #require(components.url))
            }
        }
    }

    @Test("Several requests in a row each complete over TLS")
    func sequential() async throws {
        try await withServer { base, identity in
            let session = session(pinning: identity.fingerprint)
            for _ in 0..<10 {
                let (_, response) = try await session.data(from: try pingURL(base))
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
            }
        }
    }

    @Test("The connection is TLS 1.3")
    func protocolVersion() async throws {
        try await withServer { base, identity in
            let collector = MetricsCollector(fingerprint: identity.fingerprint)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration, delegate: collector,
                                     delegateQueue: nil)
            _ = try await session.data(from: try pingURL(base))
            session.finishTasksAndInvalidate()
            #expect(await collector.version() == .TLSv13)
        }
    }
}

/// Pins like `PinningDelegate`, and records the negotiated TLS version.
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pin: PinningDelegate
    private let lock = NSLock()
    private var negotiated: tls_protocol_version_t?
    private var waiters: [CheckedContinuation<tls_protocol_version_t?, Never>] = []
    private var finished = false

    init(fingerprint: String) { pin = PinningDelegate(fingerprint: fingerprint) }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        pin.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        let version = metrics.transactionMetrics.last?.negotiatedTLSProtocolVersion
        lock.lock()
        negotiated = version
        finished = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: version) }
    }

    func version() async -> tls_protocol_version_t? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                let value = negotiated
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
