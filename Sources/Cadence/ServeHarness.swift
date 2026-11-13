#if DEBUG
import Foundation
import CadenceLibrary
import CadenceServer

/// `Cadence --serve` — runs the library server on the loopback interface, for
/// `curl` and for developing a client against a real library.
///
/// Debug builds only, like the plain-HTTP listener it starts: this file does
/// not compile into a release build. Nothing off this machine can reach it.
///
/// The API key comes from the environment variable `CADENCE_DEV_API_KEY` and
/// is never printed, so it stays out of the terminal's scrollback and out of
/// anything that captures this process's output. `docs/library-server.md`
/// shows how to set one and call the server.
@MainActor
enum ServeHarness {

    struct Options {
        /// Defaults to the app's real database. `--library` points it at
        /// another, such as one `--scan` wrote.
        var libraryPath: URL?
    }

    static let keyVariable = "CADENCE_DEV_API_KEY"
    /// Long enough that a key someone typed by hand is refused.
    static let minimumKeyLength = 32

    static func parse(_ arguments: [String]) -> Options? {
        guard arguments.contains("--serve") else { return nil }
        var libraryPath: URL?
        if let flag = arguments.firstIndex(of: "--library") {
            let value = arguments.index(after: flag)
            if arguments.indices.contains(value) {
                libraryPath = URL(
                    fileURLWithPath: (arguments[value] as NSString).expandingTildeInPath)
            }
        }
        return Options(libraryPath: libraryPath)
    }

    /// Runs until the process is interrupted.
    static func run(_ options: Options) async throws -> Int32 {
        guard let key = ProcessInfo.processInfo.environment[keyVariable],
              key.count >= minimumKeyLength else {
            FileHandle.standardError.write(Data("""
                --serve needs an API key of at least \(minimumKeyLength) characters in the \
                environment variable \(keyVariable). See docs/library-server.md.

                """.utf8))
            return 2
        }

        let libraryURL = try options.libraryPath ?? SQLiteLibraryStore.defaultURL()
        let store = try SQLiteLibraryStore(url: libraryURL)
        let artwork = try DiskArtworkStore.makeDefault()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"

        let server = LibraryServer(
            configuration: .init(serverVersion: version),
            authenticator: FixedKeyAuthenticator(key: key),
            library: store, artwork: artwork)
        let listener = try HTTPListener.loopback { await server.respond(to: $0) }
        let port = try await listener.start()

        print("""
            Cadence library server (debug, loopback only, plain HTTP)
            Library  \(libraryURL.path)
            Address  http://127.0.0.1:\(port)/rest/
            Key      read from \(keyVariable), not shown

            Ctrl-C to stop.
            """)
        // `print` is block-buffered when piped; a script waiting for the
        // address would otherwise wait for a buffer that never fills.
        fflush(stdout)

        // Parked for good: the listener works on its own queue, and Ctrl-C
        // ends the process.
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}
#endif
