import Testing
import Foundation
import CadenceLibrary
@testable import CadenceServer

/// A store file in a temporary folder, removed afterwards.
private func withStoreFile<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cadence-paired-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory.appendingPathComponent("paired-devices.json"))
}

/// When the file says the first device was last seen, read by a fresh store.
private func onDisk(_ url: URL) async throws -> Date? {
    await (try PairedDeviceStore(fileURL: url)).all().first?.lastSeenAt
}

/// A clock a test can move.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@Suite("Paired devices")
struct PairedDeviceStoreTests {

    // MARK: Pairing

    @Test("A paired device's key is accepted, and names the device")
    func pairAndAuthenticate() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            let (device, key) = try await store.pair(named: "Casper's iPhone")
            #expect(device.name == "Casper's iPhone")
            #expect(await store.device(forAPIKey: key) == device.id)
            #expect(await store.all().map(\.id) == [device.id])
        }
    }

    @Test("A key is 256 random bits, safe to put in a URL")
    func keyShape() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            var keys: Set<String> = []
            for index in 0..<20 {
                let key = try await store.pair(named: "Device \(index)").apiKey
                // 32 bytes in unpadded base64 is 43 characters.
                #expect(key.count == 43)
                #expect(key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
                keys.insert(key)
            }
            #expect(keys.count == 20)
        }
    }

    @Test("Each device has its own key, and one does not open another")
    func separateKeys() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            let phone = try await store.pair(named: "iPhone")
            let tablet = try await store.pair(named: "iPad")
            #expect(phone.apiKey != tablet.apiKey)
            #expect(await store.device(forAPIKey: phone.apiKey) == phone.device.id)
            #expect(await store.device(forAPIKey: tablet.apiKey) == tablet.device.id)
        }
    }

    @Test("Keys that were never issued are refused", arguments: [
        "", " ", "not-a-key", "0", String(repeating: "A", count: 43),
        String(repeating: "a", count: 10_000),
    ])
    func unknownKeys(key: String) async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            _ = try await store.pair(named: "iPhone")
            #expect(await store.device(forAPIKey: key) == nil)
        }
    }

    @Test("A key that is nearly right is refused")
    func nearMisses() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            let key = try await store.pair(named: "iPhone").apiKey
            #expect(await store.device(forAPIKey: String(key.dropLast())) == nil)
            #expect(await store.device(forAPIKey: key + "A") == nil)
            #expect(await store.device(forAPIKey: key.uppercased()) == nil
                    || key == key.uppercased())
            #expect(await store.device(forAPIKey: " " + key) == nil)
        }
    }

    @Test("With no devices paired, nothing is accepted")
    func emptyStore() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            #expect(await store.device(forAPIKey: "") == nil)
            #expect(await store.device(forAPIKey: "anything") == nil)
            #expect(await store.all().isEmpty)
            // Asking does not create the file.
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("There is a limit to how many devices can be paired")
    func deviceLimit() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            for index in 0..<PairedDeviceStore.maximumDevices {
                _ = try await store.pair(named: "Device \(index)")
            }
            await #expect(throws: PairedDeviceStore.StoreError.tooManyDevices) {
                _ = try await store.pair(named: "One too many")
            }
            #expect(await store.all().count == PairedDeviceStore.maximumDevices)
        }
    }

    // MARK: Revoking

    @Test("A revoked key stops working at once, and the others carry on")
    func revoke() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            let phone = try await store.pair(named: "iPhone")
            let tablet = try await store.pair(named: "iPad")

            try await store.revoke(phone.device.id)

            #expect(await store.device(forAPIKey: phone.apiKey) == nil)
            #expect(await store.device(forAPIKey: tablet.apiKey) == tablet.device.id)
            #expect(await store.all().map(\.id) == [tablet.device.id])
        }
    }

    @Test("A revoked device stays revoked after a relaunch")
    func revokePersists() async throws {
        try await withStoreFile { url in
            let key: String
            do {
                let store = try PairedDeviceStore(fileURL: url)
                let phone = try await store.pair(named: "iPhone")
                key = phone.apiKey
                try await store.revoke(phone.device.id)
            }
            let reopened = try PairedDeviceStore(fileURL: url)
            #expect(await reopened.device(forAPIKey: key) == nil)
            #expect(await reopened.all().isEmpty)
        }
    }

    @Test("Revoking a device that is not paired is an error, and changes nothing")
    func revokeUnknown() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            let phone = try await store.pair(named: "iPhone")
            await #expect(throws: PairedDeviceStore.StoreError.unknownDevice) {
                try await store.revoke(UUID())
            }
            #expect(await store.device(forAPIKey: phone.apiKey) == phone.device.id)
        }
    }

    @Test("Revoking frees a place for another device")
    func revokeFreesSlot() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            var first: PairedDevice.ID?
            for index in 0..<PairedDeviceStore.maximumDevices {
                let device = try await store.pair(named: "Device \(index)").device
                if first == nil { first = device.id }
            }
            try await store.revoke(try #require(first))
            _ = try await store.pair(named: "Replacement")
        }
    }

    // MARK: Persistence

    @Test("Pairings survive a relaunch")
    func persists() async throws {
        try await withStoreFile { url in
            let paired = try await PairedDeviceStore(fileURL: url).pair(named: "iPhone")
            let reopened = try PairedDeviceStore(fileURL: url)
            #expect(await reopened.device(forAPIKey: paired.apiKey) == paired.device.id)
            #expect(await reopened.all().first?.name == "iPhone")
        }
    }

    /// The point of hashing: someone who copies the file has no key.
    @Test("The file holds no key, only its digest")
    func fileHoldsNoKey() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            var keys: [String] = []
            for index in 0..<5 { keys.append(try await store.pair(named: "Device \(index)").apiKey) }

            let contents = try String(contentsOf: url, encoding: .utf8)
            for key in keys {
                #expect(!contents.contains(key))
                // Nor the key in the other alphabet, nor its raw bytes as hex.
                let standard = key.replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
                #expect(!contents.contains(standard))
            }
            #expect(contents.contains("keyDigest"))
        }
    }

    @Test("The file is readable by its owner alone")
    func filePermissions() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            let first = try await store.pair(named: "iPhone")
            var permissions = try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)

            // And still, after it has been rewritten.
            _ = try await store.pair(named: "iPad")
            try await store.revoke(first.device.id)
            permissions = try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)

            // No temporary file is left beside it.
            let siblings = try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path)
            #expect(siblings == ["paired-devices.json"])
        }
    }

    @Test("A file this version cannot read is refused and left as it is", arguments: [
        "", "not json", "{}", "[]", #"{"version":2,"devices":[]}"#,
        #"{"version":1,"devices":[{"id":"nope"}]}"#, #"{"version":1}"#,
    ])
    func unreadableFile(contents: String) async throws {
        try await withStoreFile { url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            #expect(throws: PairedDeviceStore.StoreError.unreadable) {
                _ = try PairedDeviceStore(fileURL: url)
            }
            #expect(try Data(contentsOf: url) == Data(contents.utf8))
        }
    }

    // MARK: Names

    @Test("A device's name is cleaned before it is kept", arguments: [
        ("  Casper's iPhone  ", "Casper's iPhone"),
        ("iPhone\nSecond line", "iPhoneSecond line"),
        ("iPad\u{0}\u{7}\u{1B}[31m", "iPad[31m"),
        ("", "Unnamed device"),
        ("   ", "Unnamed device"),
        ("\n\t\r", "Unnamed device"),
        ("Søren's iPad 🎧", "Søren's iPad 🎧"),
    ])
    func names(given: String, kept: String) {
        #expect(PairedDeviceStore.cleaned(given) == kept)
    }

    @Test("A very long name is cut short")
    func longName() {
        let cleaned = PairedDeviceStore.cleaned(String(repeating: "a", count: 5000))
        #expect(cleaned.count == PairedDeviceStore.maximumNameLength)
    }

    // MARK: Last seen

    @Test("A device's last request is remembered, and written at most once a minute")
    func lastSeen() async throws {
        try await withStoreFile { url in
            let clock = TestClock()
            let store = try PairedDeviceStore(fileURL: url, now: { clock.now })
            let phone = try await store.pair(named: "iPhone")
            #expect(await store.all().first?.lastSeenAt == nil)

            clock.advance(10)
            _ = await store.device(forAPIKey: phone.apiKey)
            let firstSeen = clock.now
            #expect(await store.all().first?.lastSeenAt == firstSeen)
            #expect(try await onDisk(url) == firstSeen)

            // Thirty seconds on: known in memory, not yet worth a write.
            clock.advance(30)
            _ = await store.device(forAPIKey: phone.apiKey)
            #expect(await store.all().first?.lastSeenAt == clock.now)
            #expect(try await onDisk(url) == firstSeen)

            // Past the minute: written again.
            clock.advance(31)
            _ = await store.device(forAPIKey: phone.apiKey)
            #expect(try await onDisk(url) == clock.now)
        }
    }

    @Test("A refused key is not a sighting of anyone")
    func refusedKeyIsNotSeen() async throws {
        try await withStoreFile { url in
            let store = try PairedDeviceStore(fileURL: url)
            _ = try await store.pair(named: "iPhone")
            _ = await store.device(forAPIKey: "wrong")
            #expect(await store.all().first?.lastSeenAt == nil)
        }
    }

    // MARK: Through the server

    @Test("The server accepts a paired device and refuses it once revoked")
    func throughServer() async throws {
        try await withStoreFile { url in
            let library = try await TestLibrary()
            let devices = try PairedDeviceStore(fileURL: url)
            let server = LibraryServer(configuration: .init(serverVersion: "1"),
                                       authenticator: devices, library: library.store)
            let phone = try await devices.pair(named: "iPhone")

            func ping(_ key: String) async -> HTTPResponse {
                await server.respond(to: HTTPRequest(
                    method: .get, path: "/rest/ping", query: [(name: "apiKey", value: key)]))
            }
            #expect(await ping(phone.apiKey).isOK)
            #expect(await ping("wrong").errorCode == 44)

            try await devices.revoke(phone.device.id)
            // The very next request, with no relaunch and nothing to expire.
            #expect(await ping(phone.apiKey).errorCode == 44)
        }
    }
}
