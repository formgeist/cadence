import Testing
import Foundation
import Network
import CadenceLibrary
@testable import CadenceServer

/// Browses for Cadence servers and reports what it sees.
private final class ServiceWatcher: @unchecked Sendable {
    private let browser: NWBrowser
    private let lock = NSLock()
    private var seen: [String: NWBrowser.Result] = [:]

    init() {
        browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: HTTPListener.bonjourType, domain: nil),
            using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.lock.withLock {
                self.seen = [:]
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        self.seen[name] = result
                    }
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "cadence.tests.browser"))
    }

    func stop() { browser.cancel() }

    func result(named name: String) -> NWBrowser.Result? { lock.withLock { seen[name] } }

    func names() -> Set<String> { lock.withLock { Set(seen.keys) } }

    /// Waits up to `seconds` for `condition` to hold.
    func wait(_ seconds: Double, until condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

@Suite("Bonjour", .serialized)
struct BonjourTests {

    private func makeIdentity() throws -> (ServerIdentityStore, URL, ServerIdentity) {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-bonjour-\(id)")
        let store = ServerIdentityStore(
            certificateURL: directory.appendingPathComponent("server-certificate.der"),
            keyTag: "com.formgeist.cadence.tests.\(id)")
        return (store, directory, try store.loadOrCreate(commonName: "Cadence Test"))
    }

    @Test("The service type is the one the plan and the iOS app agree on")
    func serviceType() {
        #expect(HTTPListener.bonjourType == "_cadence._tcp")
    }

    @Test("A sharing server can be found by name, and is gone when it stops")
    func advertised() async throws {
        let (store, directory, identity) = try makeIdentity()
        defer { store.reset(); try? FileManager.default.removeItem(at: directory) }
        let server = try await TestLibrary().server()
        let name = "Cadence Test \(UUID().uuidString.prefix(8))"

        let watcher = ServiceWatcher()
        defer { watcher.stop() }

        let listener = try HTTPListener.tls(
            identity: identity, advertisedName: name) { await server.respond(to: $0) }
        let port = try await listener.start()
        #expect(port > 0)

        let found = await watcher.wait(8) { watcher.result(named: name) != nil }
        #expect(found, "the service was not seen on the network")

        listener.stop()
        let gone = await watcher.wait(8) { watcher.result(named: name) == nil }
        #expect(gone, "the service was still advertised after the server stopped")
    }

    /// The announcement is a name, a type and a port. Nothing about the
    /// library, the paired devices or the version rides along with it.
    @Test("The announcement carries no TXT record")
    func noTXTRecord() async throws {
        let (store, directory, identity) = try makeIdentity()
        defer { store.reset(); try? FileManager.default.removeItem(at: directory) }
        let server = try await TestLibrary().server()
        let name = "Cadence Test \(UUID().uuidString.prefix(8))"
        let watcher = ServiceWatcher()
        defer { watcher.stop() }
        let listener = try HTTPListener.tls(
            identity: identity, advertisedName: name) { await server.respond(to: $0) }
        _ = try await listener.start()
        defer { listener.stop() }

        _ = await watcher.wait(8) { watcher.result(named: name) != nil }
        let result = try #require(watcher.result(named: name))
        switch result.metadata {
        case .bonjour(let record):
            #expect(record.dictionary.isEmpty)
        case .none:
            break
        @unknown default:
            Issue.record("unexpected metadata")
        }
    }

    @Test("A server started without a name is not advertised")
    func notAdvertisedByDefault() async throws {
        let (store, directory, identity) = try makeIdentity()
        defer { store.reset(); try? FileManager.default.removeItem(at: directory) }
        let server = try await TestLibrary().server()

        let watcher = ServiceWatcher()
        defer { watcher.stop() }

        // First prove browsing works here, so that seeing nothing new below
        // cannot simply mean nothing is ever seen.
        let name = "Cadence Test \(UUID().uuidString.prefix(8))"
        let named = try HTTPListener.tls(
            identity: identity, advertisedName: name) { await server.respond(to: $0) }
        _ = try await named.start()
        defer { named.stop() }
        #expect(await watcher.wait(8) { watcher.result(named: name) != nil })
        let before = watcher.names()

        // Now one with no name, listening on the network like the real one.
        let silent = try HTTPListener.tls(identity: identity) { await server.respond(to: $0) }
        _ = try await silent.start()
        defer { silent.stop() }
        try await Task.sleep(for: .seconds(2))
        #expect(watcher.names() == before)
    }
}
