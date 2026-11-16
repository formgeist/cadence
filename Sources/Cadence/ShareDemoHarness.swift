#if DEBUG
import Foundation
import CadenceCore
import CadenceLibrary
import CadenceServer

/// `Cadence --share-demo` — runs the real sharing server, TLS and pairing
/// included, and prints a pairing link, so the iPhone app can be paired and
/// tried against a library without switching sharing on in the app.
///
/// Debug builds only. It is the same server the "Share library" switch
/// starts, with three differences, all so it cannot disturb real sharing:
///
/// - **An identity of its own**, a keychain key under its own tag and a
///   certificate in its own folder. A phone paired with the demo has pinned
///   the demo's certificate, never the app's.
/// - **A device list of its own**, in that folder. Devices paired here are
///   not paired with the app.
/// - **Its own port**, 4534, so it can run beside the app's sharing on 4533.
///
/// Both are kept between runs, so a simulator stays paired across restarts.
/// `--share-demo --reset` forgets them first.
///
/// A pairing code works once and lasts five minutes. Whenever none is open,
/// the harness opens a new one and prints its link, so there is always one
/// to use: in the simulator, `xcrun simctl openurl booted '<link>'`.
@MainActor
enum ShareDemoHarness {

    struct Options {
        var libraryPath: URL?
        var reset = false
    }

    static let port: UInt16 = 4534

    static func parse(_ arguments: [String]) -> Options? {
        guard arguments.contains("--share-demo") else { return nil }
        var options = Options(reset: arguments.contains("--reset"))
        if let flag = arguments.firstIndex(of: "--library") {
            let value = arguments.index(after: flag)
            if arguments.indices.contains(value) {
                options.libraryPath = URL(
                    fileURLWithPath: (arguments[value] as NSString).expandingTildeInPath)
            }
        }
        return options
    }

    /// Runs until the process is interrupted.
    static func run(_ options: Options) async throws -> Int32 {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Cadence/share-demo", isDirectory: true)
        let identityStore = ServerIdentityStore(
            certificateURL: folder.appendingPathComponent("server-certificate.der"),
            keyTag: "com.formgeist.cadence.share-demo")
        let devicesURL = folder.appendingPathComponent("paired-devices.json")
        if options.reset {
            identityStore.reset()
            try? FileManager.default.removeItem(at: devicesURL)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let libraryURL = try options.libraryPath ?? SQLiteLibraryStore.defaultURL()
        let backend = LiveSharingBackend(
            library: try SQLiteLibraryStore(url: libraryURL),
            artwork: try DiskArtworkStore.makeDefault(),
            devicesURL: { devicesURL },
            identityStore: { identityStore },
            port: port)
        let endpoint = try await backend.start(advertisedName: "Cadence Demo")
        let host = ProcessInfo.processInfo.hostName

        print("""
            Cadence sharing demo (debug; its own identity, devices and port)
            Library      \(libraryURL.path)
            Address      https://\(host):\(endpoint.port)  (also 127.0.0.1 for the simulator)
            Fingerprint  \(endpoint.fingerprint)
            Paired       \(try await backend.devices().map(\.name).joined(separator: ", "))

            Ctrl-C to stop.
            """)
        fflush(stdout)

        // Keep a pairing code open, and print each new one's link.
        while true {
            if await backend.currentPairing() == nil, let offer = await backend.beginPairing() {
                let expires = offer.expiresAt.formatted(date: .omitted, time: .standard)
                for (label, linkHost) in [("Simulator", "127.0.0.1"), ("Phone", host)] {
                    let payload = PairingPayload(host: linkHost, port: endpoint.port,
                                                 fingerprint: endpoint.fingerprint,
                                                 token: offer.token, name: "Cadence Demo")
                    print("\(label) link (one use, until \(expires)):")
                    print("  \(payload.url?.absoluteString ?? "?")")
                }
                print("""
                    In the simulator:
                      xcrun simctl openurl booted '<the simulator link>'

                    """)
                fflush(stdout)
            }
            try await Task.sleep(for: .seconds(2))
        }
    }
}
#endif
