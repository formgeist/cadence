import Foundation
import Observation
import CadenceCore

/// Library sharing, as Preferences and the title bar see it: the switch, the
/// server's state, the paired devices and the pairing code.
///
/// **Off until asked.** Building a controller starts nothing, whatever the
/// saved setting says. The app calls `resumeIfEnabled()` once, on a normal
/// launch; the headless modes (`--scan`, `--snapshot` and the rest) never do,
/// so none of them opens a port.
///
/// **A failed start switches sharing off.** A switch that reads "on" while
/// nothing is listening would be a lie in the safe direction, but still a
/// lie, and the title bar's indicator would have to tell a second one.
@MainActor
@Observable
final class SharingController {

    enum Status: Equatable {
        case off
        case starting
        case on(SharingEndpoint)
    }

    /// A pairing code on screen.
    struct Pairing: Equatable {
        /// The `cadence://pair?…` link the QR code holds. It carries the
        /// token, so it is drawn and never written anywhere: not to a log,
        /// not to the pasteboard, not into an accessibility label.
        var link: String
        var expiresAt: Date
    }

    private(set) var isEnabled: Bool
    private(set) var status: Status = .off
    private(set) var devices: [SharedDevice] = []
    private(set) var pairing: Pairing?
    /// The name or address a device reaches this Mac by. Nil when the Mac is
    /// on no network.
    private(set) var host: String?
    /// The last thing that went wrong, in words for the listener.
    private(set) var lastError: String?
    /// How the last pairing code ended: who paired, or that nobody did.
    private(set) var notice: String?

    /// What the server is announced as, and what a device shows for it.
    let computerName: String

    var isOn: Bool {
        if case .on = status { return true }
        return false
    }

    private let backend: any SharingBackend
    private let settings: any SettingsStore
    private let hostProvider: @Sendable () -> String?
    private let pollInterval: Duration

    /// The one task that starts and stops the server. Flipping the switch
    /// twice quickly must not run a start and a stop at the same time.
    private var worker: Task<Void, Never>?
    private var pairingWatch: Task<Void, Never>?

    init(backend: any SharingBackend, settings: any SettingsStore,
         computerName: String = SharingController.defaultComputerName(),
         hostProvider: @escaping @Sendable () -> String? = { SharingHost.current() },
         pollInterval: Duration = .seconds(1)) {
        self.backend = backend
        self.settings = settings
        self.computerName = computerName
        self.hostProvider = hostProvider
        self.pollInterval = pollInterval
        isEnabled = settings.bool(forKey: .librarySharingEnabled) ?? false
    }

    /// The Mac's name from System Settings, cut to what a pairing code may
    /// carry.
    static func defaultComputerName() -> String {
        let name = (Host.current().localizedName ?? "")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Cadence" : String(name.prefix(48))
    }

    // MARK: - The switch

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        settings.set(enabled, forKey: .librarySharingEnabled)
        lastError = nil
        notice = nil
        reconcile()
    }

    /// Starts the server if sharing was on when the app last quit. Called
    /// once, by a normal launch.
    func resumeIfEnabled() {
        if isEnabled { reconcile() }
    }

    /// Waits for a start or stop in flight. For tests.
    func settle() async {
        await worker?.value
    }

    private func reconcile() {
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    /// Brings the server to what the switch says, and looks again afterwards
    /// in case the switch moved while it was working.
    private func run() async {
        defer { worker = nil }
        while true {
            switch (isEnabled, status) {
            case (true, .off):
                status = .starting
                do {
                    let endpoint = try await backend.start(advertisedName: computerName)
                    status = .on(endpoint)
                    host = hostProvider()
                } catch {
                    await backend.stop()
                    status = .off
                    isEnabled = false
                    settings.set(false, forKey: .librarySharingEnabled)
                    // Not the error's own text: that can hold a path, and
                    // nothing here should put one on screen unasked.
                    lastError = "Sharing could not start, and is off. "
                        + "Try again; if it keeps failing, restart Cadence."
                }
                await refreshDevices()

            case (false, .on):
                endPairing()
                await backend.stop()
                status = .off
                host = nil

            default:
                return
            }
        }
    }

    // MARK: - Devices

    func refreshDevices() async {
        do {
            devices = try await backend.devices()
        } catch {
            lastError = "The list of paired devices could not be read."
        }
    }

    /// Takes a device's access away. It is locked out at once; what can
    /// fail is writing that down, and then it must be said, because a
    /// device removed only in memory is back when the app restarts.
    func revoke(_ device: SharedDevice) async {
        do {
            try await backend.revoke(device.id)
            lastError = nil
        } catch {
            lastError = "\(device.name) can no longer connect, but the change could not be "
                + "saved. If it is listed again after Cadence restarts, remove it again."
        }
        await refreshDevices()
    }

    // MARK: - Pairing

    func beginPairing() async {
        guard case .on(let endpoint) = status else { return }
        notice = nil
        host = hostProvider()
        guard let host else {
            lastError = "This Mac is not on a network, so there is nothing for a device to "
                + "connect to."
            return
        }
        guard let offer = await backend.beginPairing(),
              let link = Self.link(host: host, endpoint: endpoint, token: offer.token,
                                   name: computerName) else {
            lastError = "A pairing code could not be made."
            return
        }
        lastError = nil
        pairing = Pairing(link: link, expiresAt: offer.expiresAt)
        watchPairing(knownDevices: Set(devices.map(\.id)))
    }

    func cancelPairing() async {
        endPairing()
        await backend.cancelPairing()
    }

    private func endPairing() {
        pairingWatch?.cancel()
        pairingWatch = nil
        pairing = nil
    }

    /// The link, checked by the same reader the phone uses: a code the Mac
    /// shows must be one the phone accepts.
    static func link(host: String, endpoint: SharingEndpoint, token: String,
                     name: String) -> String? {
        let payload = PairingPayload(host: host, port: endpoint.port,
                                     fingerprint: endpoint.fingerprint, token: token, name: name)
        guard let url = payload.url, (try? PairingPayload(url: url)) == payload else { return nil }
        return url.absoluteString
    }

    /// Takes the code off screen when it stops working: used, run out, or
    /// spoiled by wrong guesses. The server decides; this only asks.
    private func watchPairing(knownDevices: Set<SharedDevice.ID>) {
        pairingWatch?.cancel()
        pairingWatch = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard let self, !Task.isCancelled else { return }
                let open = await self.backend.currentPairing() != nil
                await self.refreshDevices()
                guard !Task.isCancelled else { return }
                if !open {
                    let added = self.devices.first { !knownDevices.contains($0.id) }
                    self.notice = added.map { "Paired with \($0.name)." }
                        ?? "The code stopped working before a device used it. Nothing was paired."
                    self.pairing = nil
                    self.pairingWatch = nil
                    return
                }
            }
        }
    }
}
