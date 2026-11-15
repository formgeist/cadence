import Testing
import Foundation
import CadenceCore
import CadenceLibrary
import CadenceServer
@testable import Cadence

/// A server that does what the test tells it and remembers what was asked.
private actor FakeBackend: SharingBackend {
    struct Refused: Error {}

    static let endpoint = SharingEndpoint(
        port: 4533, fingerprint: String(repeating: "ab", count: 32))

    var failsToStart = false
    var failsToRevoke = false
    var startDelay: Duration = .zero
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var isRunning = false
    private(set) var advertisedNames: [String] = []
    var paired: [SharedDevice] = []
    var offer: PairingOffer?

    func setFailsToStart(_ value: Bool) { failsToStart = value }
    func setFailsToRevoke(_ value: Bool) { failsToRevoke = value }
    func setStartDelay(_ value: Duration) { startDelay = value }
    func setPaired(_ devices: [SharedDevice]) { paired = devices }

    /// What the server does when a phone presents the token.
    func redeem(as name: String) {
        offer = nil
        paired.append(SharedDevice(id: UUID(), name: name, pairedAt: Date(), lastSeenAt: nil))
    }

    func expire() { offer = nil }

    func start(advertisedName: String) async throws -> SharingEndpoint {
        starts += 1
        advertisedNames.append(advertisedName)
        if startDelay > .zero { try? await Task.sleep(for: startDelay) }
        if failsToStart { throw Refused() }
        isRunning = true
        return Self.endpoint
    }

    func stop() async {
        stops += 1
        isRunning = false
        offer = nil
    }

    func devices() async throws -> [SharedDevice] { paired }

    func revoke(_ id: SharedDevice.ID) async throws {
        paired.removeAll { $0.id == id }
        if failsToRevoke { throw Refused() }
    }

    func beginPairing() async -> PairingOffer? {
        guard isRunning else { return nil }
        let made = PairingOffer(token: String(repeating: "t0k-", count: 8),
                                expiresAt: Date().addingTimeInterval(300))
        offer = made
        return made
    }

    func currentPairing() async -> PairingOffer? { offer }
    func cancelPairing() async { offer = nil }
}

@Suite("Sharing controller")
@MainActor
struct SharingControllerTests {

    private func make(
        _ backend: FakeBackend, settings: InMemorySettingsStore = InMemorySettingsStore(),
        host: String? = "studio-mac.local"
    ) -> SharingController {
        SharingController(backend: backend, settings: settings, computerName: "Studio Mac",
                          hostProvider: { host }, pollInterval: .milliseconds(20))
    }

    private func wait(_ seconds: Double = 3, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - Off until asked

    @Test("Sharing is off for someone who has never switched it on")
    func offByDefault() async {
        let backend = FakeBackend()
        let sharing = make(backend)
        #expect(!sharing.isEnabled)
        #expect(sharing.status == .off)
        sharing.resumeIfEnabled()
        await sharing.settle()
        #expect(await backend.starts == 0)
    }

    /// The headless modes build a controller and never call
    /// `resumeIfEnabled`. With the setting saved as on, that must still open
    /// nothing.
    @Test("Building a controller starts nothing, even with sharing saved as on")
    func buildingStartsNothing() async {
        let settings = InMemorySettingsStore()
        settings.set(true, forKey: .librarySharingEnabled)
        let backend = FakeBackend()
        let sharing = make(backend, settings: settings)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sharing.isEnabled)
        #expect(sharing.status == .off)
        #expect(!sharing.isOn)
        #expect(await backend.starts == 0)
    }

    @Test("A normal launch starts the server when sharing was left on")
    func resumes() async {
        let settings = InMemorySettingsStore()
        settings.set(true, forKey: .librarySharingEnabled)
        let backend = FakeBackend()
        let sharing = make(backend, settings: settings)
        sharing.resumeIfEnabled()
        await sharing.settle()
        #expect(sharing.status == .on(FakeBackend.endpoint))
        #expect(await backend.advertisedNames == ["Studio Mac"])
    }

    // MARK: - The switch

    @Test("Switching on starts the server and remembers the choice")
    func switchOn() async {
        let settings = InMemorySettingsStore()
        let backend = FakeBackend()
        let sharing = make(backend, settings: settings)
        sharing.setEnabled(true)
        #expect(sharing.status == .off || sharing.status == .starting)
        await sharing.settle()
        #expect(sharing.isOn)
        #expect(sharing.host == "studio-mac.local")
        #expect(settings.bool(forKey: .librarySharingEnabled) == true)
    }

    @Test("Switching off stops the server, closes the code and remembers the choice")
    func switchOff() async {
        let settings = InMemorySettingsStore()
        let backend = FakeBackend()
        let sharing = make(backend, settings: settings)
        sharing.setEnabled(true)
        await sharing.settle()
        await sharing.beginPairing()
        #expect(sharing.pairing != nil)

        sharing.setEnabled(false)
        await sharing.settle()
        #expect(sharing.status == .off)
        #expect(sharing.pairing == nil)
        #expect(await !backend.isRunning)
        #expect(await backend.offer == nil)
        #expect(settings.bool(forKey: .librarySharingEnabled) == false)
    }

    @Test("A start that fails leaves sharing off, says so, and is not remembered as on")
    func failedStart() async {
        let settings = InMemorySettingsStore()
        let backend = FakeBackend()
        await backend.setFailsToStart(true)
        let sharing = make(backend, settings: settings)
        sharing.setEnabled(true)
        await sharing.settle()
        #expect(!sharing.isEnabled)
        #expect(sharing.status == .off)
        #expect(sharing.lastError != nil)
        #expect(settings.bool(forKey: .librarySharingEnabled) == false)
        // One attempt, not a loop of them.
        #expect(await backend.starts == 1)
    }

    @Test("Off, on, off in quick succession ends off, with nothing left listening")
    func quickToggles() async {
        let backend = FakeBackend()
        await backend.setStartDelay(.milliseconds(50))
        let sharing = make(backend)
        sharing.setEnabled(true)
        try? await Task.sleep(for: .milliseconds(10))
        sharing.setEnabled(false)
        sharing.setEnabled(true)
        sharing.setEnabled(false)
        await sharing.settle()
        #expect(sharing.status == .off)
        #expect(await !backend.isRunning)
    }

    @Test("On, off, on in quick succession ends on")
    func quickTogglesEndingOn() async {
        let backend = FakeBackend()
        await backend.setStartDelay(.milliseconds(50))
        let sharing = make(backend)
        sharing.setEnabled(true)
        sharing.setEnabled(false)
        sharing.setEnabled(true)
        await sharing.settle()
        #expect(sharing.isOn)
        #expect(await backend.isRunning)
    }

    // MARK: - Pairing

    @Test("The code on screen is one the phone's reader accepts, with this server's details")
    func pairingLink() async throws {
        let backend = FakeBackend()
        let sharing = make(backend)
        sharing.setEnabled(true)
        await sharing.settle()
        await sharing.beginPairing()

        let pairing = try #require(sharing.pairing)
        let payload = try PairingPayload(url: try #require(URL(string: pairing.link)))
        #expect(payload.host == "studio-mac.local")
        #expect(payload.port == 4533)
        #expect(payload.fingerprint == FakeBackend.endpoint.fingerprint)
        #expect(payload.token == String(repeating: "t0k-", count: 8))
        #expect(payload.name == "Studio Mac")
    }

    @Test("A Mac name with spaces, an apostrophe and an emoji still makes a code")
    func awkwardName() throws {
        let link = try #require(SharingController.link(
            host: "192.168.1.20", endpoint: FakeBackend.endpoint,
            token: String(repeating: "a", count: 43), name: "Vera’s Mac & Büro 🎧"))
        let payload = try PairingPayload(url: try #require(URL(string: link)))
        #expect(payload.name == "Vera’s Mac & Büro 🎧")
    }

    @Test("No code is made while sharing is off")
    func noCodeWhenOff() async {
        let backend = FakeBackend()
        let sharing = make(backend)
        await sharing.beginPairing()
        #expect(sharing.pairing == nil)
        #expect(await backend.offer == nil)
    }

    @Test("A Mac on no network says so instead of showing a code nothing can use")
    func noNetwork() async {
        let backend = FakeBackend()
        let sharing = make(backend, host: nil)
        sharing.setEnabled(true)
        await sharing.settle()
        await sharing.beginPairing()
        #expect(sharing.pairing == nil)
        #expect(sharing.lastError != nil)
        #expect(await backend.offer == nil)
    }

    @Test("When a device pairs, the code leaves the screen and the device is listed")
    func pairingCompletes() async {
        let backend = FakeBackend()
        let sharing = make(backend)
        sharing.setEnabled(true)
        await sharing.settle()
        await sharing.beginPairing()

        await backend.redeem(as: "Vera’s iPhone")
        #expect(await wait { sharing.pairing == nil })
        #expect(sharing.devices.map(\.name) == ["Vera’s iPhone"])
        #expect(sharing.notice == "Paired with Vera’s iPhone.")
    }

    @Test("When the code runs out, it leaves the screen and nothing is paired")
    func pairingExpires() async {
        let backend = FakeBackend()
        let sharing = make(backend)
        sharing.setEnabled(true)
        await sharing.settle()
        await sharing.beginPairing()

        await backend.expire()
        #expect(await wait { sharing.pairing == nil })
        #expect(sharing.devices.isEmpty)
        #expect(sharing.notice?.contains("Nothing was paired") == true)
    }

    @Test("Closing the code cancels it on the server")
    func cancelPairing() async {
        let backend = FakeBackend()
        let sharing = make(backend)
        sharing.setEnabled(true)
        await sharing.settle()
        await sharing.beginPairing()
        #expect(await backend.offer != nil)

        await sharing.cancelPairing()
        #expect(sharing.pairing == nil)
        #expect(await backend.offer == nil)
        // Closed by the listener: no "it ran out" note afterwards.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(sharing.notice == nil)
    }

    // MARK: - Devices

    private let phone = SharedDevice(id: UUID(), name: "Vera’s iPhone",
                                     pairedAt: Date(timeIntervalSince1970: 1_794_000_000),
                                     lastSeenAt: nil)

    @Test("Paired devices are listed with sharing off, so access can be taken away")
    func listedWhenOff() async {
        let backend = FakeBackend()
        await backend.setPaired([phone])
        let sharing = make(backend)
        await sharing.refreshDevices()
        #expect(sharing.devices == [phone])

        await sharing.revoke(phone)
        #expect(sharing.devices.isEmpty)
        #expect(sharing.lastError == nil)
        #expect(await backend.starts == 0)
    }

    @Test("A removal that could not be saved is reported, not passed over")
    func revokeNotSaved() async {
        let backend = FakeBackend()
        await backend.setPaired([phone])
        await backend.setFailsToRevoke(true)
        let sharing = make(backend)
        await sharing.refreshDevices()

        await sharing.revoke(phone)
        #expect(sharing.lastError?.contains("could not be saved") == true)
        #expect(sharing.lastError?.contains("Vera’s iPhone") == true)
    }

    // MARK: - Words

    @Test("A device's history reads as a person would say it")
    func history() {
        let now = Date(timeIntervalSince1970: 1_794_700_000)
        var device = phone
        #expect(SharingSettings.history(of: device, now: now).hasSuffix("Has not connected yet"))
        device.lastSeenAt = now.addingTimeInterval(-30)
        #expect(SharingSettings.history(of: device, now: now).hasSuffix("Connected just now"))
        device.lastSeenAt = now.addingTimeInterval(-3 * 3600)
        #expect(SharingSettings.history(of: device, now: now).contains("Last connected"))
    }

    @Test("The fingerprint is shown in sixteen groups of four")
    func fingerprintGroups() {
        let shown = SharingSettings.grouped(String(repeating: "0a1b", count: 16))
        let lines = shown.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.split(separator: " ").count == 8 })
        #expect(shown.hasPrefix("0A1B 0A1B"))
    }

    @Test("The preview server's details make a valid code")
    func previewIsValid() async throws {
        let backend = PreviewSharingBackend()
        let offer = try #require(await backend.beginPairing())
        #expect(SharingController.link(
            host: "studio-mac.local", endpoint: PreviewSharingBackend.endpoint,
            token: offer.token, name: "Studio Mac") != nil)
    }
}

/// The real backend, against a scratch library, a scratch device file and a
/// keychain item of its own: never the user's.
@Suite("Live sharing backend", .serialized)
struct LiveSharingBackendTests {

    private struct Scratch {
        let directory: URL
        let identity: ServerIdentityStore
        let backend: LiveSharingBackend

        init() throws {
            let id = UUID().uuidString
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cadence-sharing-\(id)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let identity = ServerIdentityStore(
                certificateURL: directory.appendingPathComponent("server-certificate.der"),
                keyTag: "com.formgeist.cadence.tests.\(id)")
            let library = try SQLiteLibraryStore(
                url: directory.appendingPathComponent("library.sqlite"))
            self.directory = directory
            self.identity = identity
            backend = LiveSharingBackend(
                library: library, artwork: nil,
                devicesURL: { directory.appendingPathComponent("paired-devices.json") },
                identityStore: { identity }, port: nil, serverVersion: "test")
        }

        func cleanUp() {
            identity.reset()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("It starts on a port, with the certificate's fingerprint, and keeps both apart from the user's")
    func starts() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let endpoint = try await scratch.backend.start(advertisedName: "Cadence Test")
        #expect(endpoint.port > 0)
        #expect(endpoint.fingerprint.count == 64)
        #expect(endpoint.fingerprint == (try scratch.identity.load())?.fingerprint)
        await scratch.backend.stop()
    }

    @Test("Stopping and starting again keeps the same certificate, so paired devices still trust it")
    func sameCertificateAcrossRestarts() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let first = try await scratch.backend.start(advertisedName: "Cadence Test")
        await scratch.backend.stop()
        let second = try await scratch.backend.start(advertisedName: "Cadence Test")
        await scratch.backend.stop()
        #expect(first.fingerprint == second.fingerprint)
    }

    @Test("A pairing code exists only while the server runs, and stopping closes it")
    func pairingFollowsTheServer() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        #expect(await scratch.backend.beginPairing() == nil)

        _ = try await scratch.backend.start(advertisedName: "Cadence Test")
        let offer = try #require(await scratch.backend.beginPairing())
        #expect(offer.token.count >= 32)
        #expect(await scratch.backend.currentPairing() == offer)

        await scratch.backend.stop()
        #expect(await scratch.backend.currentPairing() == nil)
        #expect(await scratch.backend.beginPairing() == nil)
    }

    @Test("With nobody paired the list is empty, and removing an unknown device is not an error")
    func devices() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        #expect(try await scratch.backend.devices().isEmpty)
        try await scratch.backend.revoke(UUID())
    }

    @Test("A taken port is not a reason to fail: another one is used")
    func portTaken() async throws {
        let first = try Scratch()
        defer { first.cleanUp() }
        let held = try await first.backend.start(advertisedName: "Cadence Test A")

        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-sharing-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = ServerIdentityStore(
            certificateURL: directory.appendingPathComponent("server-certificate.der"),
            keyTag: "com.formgeist.cadence.tests.\(id)")
        defer { identity.reset(); try? FileManager.default.removeItem(at: directory) }
        let second = LiveSharingBackend(
            library: try SQLiteLibraryStore(url: directory.appendingPathComponent("library.sqlite")),
            artwork: nil,
            devicesURL: { directory.appendingPathComponent("paired-devices.json") },
            identityStore: { identity }, port: held.port, serverVersion: "test")

        let endpoint = try await second.start(advertisedName: "Cadence Test B")
        #expect(endpoint.port > 0)
        #expect(endpoint.port != held.port)
        await second.stop()
        await first.backend.stop()
    }
}
