import Foundation
import CadenceLibrary
import CadenceServer

/// A paired device, as Preferences shows it. The server's own record also
/// holds the digest of the device's key, which nothing above the server has
/// any use for.
struct SharedDevice: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var pairedAt: Date
    var lastSeenAt: Date?
}

/// Where a running server can be reached, less the host: the Mac's name on
/// the network can change while the server runs, so it is asked for when it
/// is needed.
struct SharingEndpoint: Equatable, Sendable {
    var port: UInt16
    /// SHA-256 of the server's certificate, 64 lowercase hex digits.
    var fingerprint: String
}

/// An open pairing code. The token is a secret until it is used or runs out:
/// it goes into the QR code and nowhere else.
struct PairingOffer: Equatable, Sendable {
    var token: String
    var expiresAt: Date
}

/// What `SharingController` needs from the server. A protocol so the
/// controller's logic can be tested without a listener, a keychain or a
/// network, and so preview mode never opens a port.
protocol SharingBackend: Sendable {
    /// Starts the server and announces it under `advertisedName`.
    func start(advertisedName: String) async throws -> SharingEndpoint
    /// Stops listening and closes any open pairing code. Safe to call when
    /// nothing is running.
    func stop() async
    func devices() async throws -> [SharedDevice]
    /// The device's key stops working before this returns, even when it
    /// throws: a throw means the change could not be written to disk.
    func revoke(_ id: SharedDevice.ID) async throws
    /// Nil when the server is not running.
    func beginPairing() async -> PairingOffer?
    /// The code still open, or nil once it has been used, has run out or was
    /// cancelled.
    func currentPairing() async -> PairingOffer?
    func cancelPairing() async
}

/// The real server: the paired-device file, the identity in the keychain, the
/// TLS listener and its Bonjour announcement.
///
/// Nothing is touched until it is asked for. Building one opens no file and
/// no port; the keychain is first read when sharing is switched on, so an app
/// that never shares never asks for it.
actor LiveSharingBackend: SharingBackend {

    /// The port asked for first. Fixed, so a paired device finds the server
    /// where it left it; if another program holds it, the system picks one
    /// and the Bonjour announcement carries the difference.
    static let preferredPort: UInt16 = 4533

    private let library: SQLiteLibraryStore
    private let artwork: DiskArtworkStore?
    private let devicesURL: @Sendable () throws -> URL
    private let identityStore: @Sendable () throws -> ServerIdentityStore
    private let port: UInt16?
    private let serverVersion: String

    private var deviceStore: PairedDeviceStore?
    private var listener: HTTPListener?
    private var pairing: PairingSession?

    /// The defaults are the app's real file and keychain item. Tests pass
    /// their own, so they never read or replace the user's.
    init(library: SQLiteLibraryStore, artwork: DiskArtworkStore?,
         devicesURL: @escaping @Sendable () throws -> URL = { try PairedDeviceStore.defaultURL() },
         identityStore: @escaping @Sendable () throws -> ServerIdentityStore
            = { try ServerIdentityStore.standard() },
         port: UInt16? = LiveSharingBackend.preferredPort,
         serverVersion: String = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") {
        self.library = library
        self.artwork = artwork
        self.devicesURL = devicesURL
        self.identityStore = identityStore
        self.port = port
        self.serverVersion = serverVersion
    }

    /// One store for the life of the app. The server and Preferences must
    /// see the same devices: a revoke has to reach the store the server asks.
    private func store() throws -> PairedDeviceStore {
        if let deviceStore { return deviceStore }
        let opened = try PairedDeviceStore(fileURL: try devicesURL())
        deviceStore = opened
        return opened
    }

    func start(advertisedName: String) async throws -> SharingEndpoint {
        if listener != nil { await stop() }

        let devices = try store()
        let identity = try identityStore().loadOrCreate(commonName: "Cadence Library")
        let session = PairingSession(devices: devices)
        let server = LibraryServer(
            configuration: .init(serverVersion: serverVersion),
            authenticator: devices, library: library, artwork: artwork, pairing: session)

        func open(on port: UInt16?) async throws -> (HTTPListener, UInt16) {
            let listener = try HTTPListener.tls(
                identity: identity, port: port, advertisedName: advertisedName
            ) { await server.respond(to: $0) }
            do {
                return (listener, try await listener.start())
            } catch {
                listener.stop()
                throw error
            }
        }

        let opened: (HTTPListener, UInt16)
        if let port {
            do {
                opened = try await open(on: port)
            } catch {
                // Most likely the port is taken. Any free one will do.
                opened = try await open(on: nil)
            }
        } else {
            opened = try await open(on: nil)
        }

        listener = opened.0
        pairing = session
        return SharingEndpoint(port: opened.1, fingerprint: identity.fingerprint)
    }

    func stop() async {
        listener?.stop()
        listener = nil
        await pairing?.cancel()
        pairing = nil
    }

    func devices() async throws -> [SharedDevice] {
        try await store().all().map {
            SharedDevice(id: $0.id, name: $0.name, pairedAt: $0.pairedAt, lastSeenAt: $0.lastSeenAt)
        }
    }

    func revoke(_ id: SharedDevice.ID) async throws {
        do {
            try await store().revoke(id)
        } catch PairedDeviceStore.StoreError.unknownDevice {
            // Already gone, which is what was asked for.
        }
    }

    func beginPairing() async -> PairingOffer? {
        guard listener != nil, let pairing else { return nil }
        let code = await pairing.begin()
        return PairingOffer(token: code.token, expiresAt: code.expiresAt)
    }

    func currentPairing() async -> PairingOffer? {
        guard let code = await pairing?.current() else { return nil }
        return PairingOffer(token: code.token, expiresAt: code.expiresAt)
    }

    func cancelPairing() async {
        await pairing?.cancel()
    }
}

/// Stands in when the library database did not open: there is nothing to
/// share, so it refuses to start and lists nothing.
struct UnavailableSharingBackend: SharingBackend {
    struct NoLibrary: Error {}

    func start(advertisedName: String) async throws -> SharingEndpoint { throw NoLibrary() }
    func stop() async {}
    func devices() async throws -> [SharedDevice] { [] }
    func revoke(_ id: SharedDevice.ID) async throws {}
    func beginPairing() async -> PairingOffer? { nil }
    func currentPairing() async -> PairingOffer? { nil }
    func cancelPairing() async {}
}

/// Preview mode's server: canned answers, no port, no file, no keychain.
/// Design review and snapshots see the sharing rows filled in and reach
/// nothing real.
actor PreviewSharingBackend: SharingBackend {
    static let endpoint = SharingEndpoint(
        port: LiveSharingBackend.preferredPort,
        fingerprint: "4f1c9a07d2e85b36a1c04e7f9b2d6385e0a74c19d35f8b62c7e1a9045d3b8f26")

    static let devices = [
        SharedDevice(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                     name: "Vera’s iPhone",
                     pairedAt: Date(timeIntervalSince1970: 1_793_000_000),
                     lastSeenAt: Date(timeIntervalSince1970: 1_794_700_000)),
        SharedDevice(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                     name: "Studio iPad",
                     pairedAt: Date(timeIntervalSince1970: 1_794_200_000),
                     lastSeenAt: nil),
    ]

    private var current = PreviewSharingBackend.devices
    private var offer: PairingOffer?

    func start(advertisedName: String) async throws -> SharingEndpoint { Self.endpoint }
    func stop() async { offer = nil }
    func devices() async throws -> [SharedDevice] { current }
    func revoke(_ id: SharedDevice.ID) async throws { current.removeAll { $0.id == id } }

    func beginPairing() async -> PairingOffer? {
        let made = PairingOffer(token: String(repeating: "preview-", count: 5) + "abc",
                                expiresAt: Date().addingTimeInterval(300))
        offer = made
        return made
    }

    func currentPairing() async -> PairingOffer? { offer }
    func cancelPairing() async { offer = nil }
}

/// The name a phone on the same network can reach this Mac by.
enum SharingHost {

    /// The Mac's Bonjour name when it has one, else its address on the local
    /// network. The name is preferred because it survives the router handing
    /// the Mac a new address.
    static func current() -> String? {
        localName() ?? localAddress()
    }

    /// `studio-mac.local`, or nil when the Mac's host name is something else
    /// (a name a router or a company network gave it), which a phone might
    /// not be able to look up.
    static func localName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return nil }
        let name = String(cString: buffer).lowercased()
        guard name.hasSuffix(".local"), name.count > ".local".count,
              name.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
                      || byte == 45 || byte == 46
              }) else { return nil }
        return name
    }

    /// The first IPv4 address of an interface that is up, skipping loopback
    /// and the self-assigned range a Mac uses when it has no network.
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("169.254.") { return text }
        }
        return nil
    }
}
