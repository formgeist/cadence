import Testing
import Foundation
import CadenceCore
import CadenceLibrary
@testable import CadenceServer
@testable import CadenceRemote

/// A real server, over TLS on the loopback interface, with pairing open: the
/// whole path a phone takes, minus the camera and the Wi-Fi.
final class LiveServer: Sendable {
    let directory: URL
    let identityStore: ServerIdentityStore
    let identity: ServerIdentity
    let devices: PairedDeviceStore
    let pairing: PairingSession
    let store: SQLiteLibraryStore
    let artwork: DiskArtworkStore
    let listener: HTTPListener
    let port: UInt16
    /// The bytes of the one song's file.
    let audio: Data

    init() async throws {
        let id = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-remote-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        identityStore = ServerIdentityStore(
            certificateURL: directory.appendingPathComponent("server-certificate.der"),
            keyTag: "com.formgeist.cadence.tests.\(id)")
        identity = try identityStore.loadOrCreate(commonName: "Cadence Test")

        // A file large enough to arrive in several pieces, with bytes that
        // differ from place to place so a misordered piece would show.
        audio = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
        let file = directory.appendingPathComponent("01 Morning Static.flac")
        try audio.write(to: file)

        store = try SQLiteLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.upsert([
            Track(url: file, title: "Morning Static", artist: "Vera Lindqvist",
                  albumArtist: "Vera Lindqvist", albumTitle: "Sound of the Slow Hours",
                  genre: "Ambient", year: 2023, trackNumber: 1, discNumber: 1, duration: 201,
                  format: .cd, dateAdded: Date(timeIntervalSince1970: 1_700_000_000)),
            Track(url: directory.appendingPathComponent("02 Slow Hours.flac"),
                  title: "Slow Hours", artist: "Vera Lindqvist", albumArtist: "Vera Lindqvist",
                  albumTitle: "Sound of the Slow Hours", year: 2023, trackNumber: 2,
                  discNumber: 1, duration: 202, format: .cd,
                  dateAdded: Date(timeIntervalSince1970: 1_700_000_000)),
        ])

        artwork = try DiskArtworkStore(root: directory.appendingPathComponent("artwork"))
        devices = try PairedDeviceStore(fileURL: directory.appendingPathComponent("devices.json"))
        pairing = PairingSession(devices: devices)
        let server = LibraryServer(configuration: .init(serverVersion: "9.8.7"),
                                   authenticator: devices, library: store, artwork: artwork,
                                   pairing: pairing)
        listener = try HTTPListener.tls(identity: identity, loopbackOnly: true) {
            await server.respond(to: $0)
        }
        port = try await listener.start()
    }

    /// What the Mac would put in its QR code right now.
    func pairingCode() async -> PairingPayload {
        let code = await pairing.begin()
        return PairingPayload(host: "127.0.0.1", port: port, fingerprint: identity.fingerprint,
                              token: code.token, name: "Test Mac")
    }

    func pair(cache: RemoteMetadataCache? = nil) async throws -> RemoteLibraryClient {
        RemoteLibraryClient(credentials: try await RemotePairing.pair(
            await pairingCode(), deviceName: "Test Phone"), cache: cache)
    }

    func stop() {
        listener.stop()
        identityStore.reset()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Runs `body` against a fresh server, and removes it afterwards whatever
/// happens.
func withServer(_ body: (LiveServer) async throws -> Void) async throws {
    let server = try await LiveServer()
    defer { server.stop() }
    try await body(server)
}

func expectError(
    _ expected: RemoteError, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("Expected \(expected), but nothing was thrown", sourceLocation: sourceLocation)
    } catch let error as RemoteError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected \(expected), got \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("Remote client against a live server", .serialized)
struct RemoteClientTests {

    @Test("Pairs, lists the library and fetches a song's bytes")
    func endToEnd() async throws {
        try await withServer { server in
            let client = try await server.pair()
            #expect(client.credentials.server.fingerprint == server.identity.fingerprint)
            #expect(client.credentials.server.name == "Test Mac")
            #expect(await server.devices.all().map(\.name) == ["Test Phone"])

            let info = try await client.connect()
            #expect(info.serverVersion == "9.8.7")
            #expect(info.protocolVersion == RemoteLibraryClient.protocolVersion)

            let index = try await client.artists()
            let artist = try #require(index.flatMap(\.artist).first)
            #expect(artist.name == "Vera Lindqvist")

            let withAlbums = try await client.artist(id: artist.id)
            let albumID = try #require(withAlbums.album?.first?.id)
            let album = try await client.album(id: albumID)
            #expect(album.name == "Sound of the Slow Hours")
            #expect(album.song?.map(\.title) == ["Morning Static", "Slow Hours"])

            let song = try #require(album.song?.first)
            #expect(song.suffix == "flac")
            #expect(try await client.song(id: song.id).title == "Morning Static")

            let destination = server.directory
                .appendingPathComponent("phone-cache/\(song.id).flac")
            try await client.download(songID: song.id, to: destination)
            // Compared as a Bool: a failed `==` on 300,000 bytes makes the
            // test framework spend minutes printing the difference.
            let arrived = try Data(contentsOf: destination) == server.audio
            #expect(arrived)
        }
    }

    @Test("Album lists, search, playlists and likes decode")
    func browsing() async throws {
        try await withServer { server in
            let client = try await server.pair()
            #expect(try await client.albums(.newest).map(\.name) == ["Sound of the Slow Hours"])
            #expect(try await client.albums(.byYear(from: 2020, to: 2025)).count == 1)
            #expect(try await client.albums(.byGenre("ambient")).count == 1)
            #expect(try await client.albums(.alphabeticalByName, size: 10, offset: 1).isEmpty)

            let found = try await client.search("slow hours")
            #expect(found.album.map(\.name) == ["Sound of the Slow Hours"])
            #expect(found.song.map(\.title).contains("Slow Hours"))
            // Everything, a page at a time.
            #expect(try await client.search("").song.count == 2)

            #expect(try await client.playlists().isEmpty)
            let starred = try await client.starred()
            #expect(starred.song.isEmpty && starred.album.isEmpty && starred.artist.isEmpty)
        }
    }

    @Test("A wrong certificate fingerprint is refused before the token is sent")
    func wrongFingerprint() async throws {
        try await withServer { server in
            var code = await server.pairingCode()
            let impostor = try SelfSignedCertificate.make(
                commonName: "Impostor", privateKey: try SelfSignedCertificate.makeEphemeralKey())
            code.fingerprint = impostor.fingerprint
            await expectError(.untrustedServer) {
                _ = try await RemotePairing.pair(code, deviceName: "Test Phone")
            }
            #expect(await server.devices.all().isEmpty)

            // The token never reached the server, so it still works.
            code.fingerprint = server.identity.fingerprint
            _ = try await RemotePairing.pair(code, deviceName: "Test Phone")
        }
    }

    @Test("A paired client whose pin no longer matches is refused")
    func pinnedClientRefusesChangedCertificate() async throws {
        try await withServer { server in
            let paired = try await server.pair()
            var credentials = paired.credentials
            credentials.server.fingerprint = String(repeating: "0", count: 64)
            await expectError(.untrustedServer) {
                try await RemoteLibraryClient(credentials: credentials).connect()
            }
            // The real pin still works afterwards: a refusal belongs to the
            // request that met it.
            try await paired.connect()
        }
    }

    @Test("A wrong or spent pairing token is refused")
    func refusedToken() async throws {
        try await withServer { server in
            var code = await server.pairingCode()
            let token = code.token
            code.token = String(repeating: "A", count: 43)
            await expectError(.pairingRefused) {
                _ = try await RemotePairing.pair(code, deviceName: "Test Phone")
            }

            code.token = token
            _ = try await RemotePairing.pair(code, deviceName: "Test Phone")
            await expectError(.pairingRefused) {
                _ = try await RemotePairing.pair(code, deviceName: "Second Phone")
            }
        }
    }

    @Test("A revoked device is told it is no longer paired")
    func revoked() async throws {
        try await withServer { server in
            let client = try await server.pair()
            try await client.connect()
            let id = try #require(UUID(uuidString: client.credentials.deviceID))
            try await server.devices.revoke(id)
            await expectError(.notPaired) { try await client.connect() }
            await expectError(.notPaired) { _ = try await client.artists() }
        }
    }

    @Test("Unknown ids are not found")
    func notFound() async throws {
        try await withServer { server in
            let client = try await server.pair()
            await expectError(.notFound) {
                _ = try await client.song(id: "tr-" + UUID().uuidString.lowercased())
            }
            await expectError(.notFound) { _ = try await client.album(id: "nothing") }
            let destination = server.directory.appendingPathComponent("missing.flac")
            await expectError(.notFound) {
                try await client.download(songID: "tr-" + UUID().uuidString.lowercased(),
                                          to: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            // A song whose file is gone from the Mac.
            let gone = try #require(try await client.search("slow hours").song
                .first { $0.title == "Slow Hours" })
            await expectError(.notFound) {
                try await client.download(songID: gone.id, to: destination)
            }
        }
    }

    @Test("A server that is not there is unreachable")
    func unreachable() async throws {
        let server = try await LiveServer()
        let client = try await server.pair()
        server.stop()
        await expectError(.unreachable) { try await client.connect() }
    }

    @Test("A cancelled download is a cancellation, not an error to show")
    func cancelled() async throws {
        try await withServer { server in
            let client = try await server.pair()
            let song = try #require(try await client.search("morning").song.first)
            let task = Task {
                try await client.download(songID: song.id,
                                          to: server.directory.appendingPathComponent("x.flac"))
            }
            task.cancel()
            do {
                try await task.value
                // Finishing before the cancel arrived is also correct.
            } catch {
                #expect(error is CancellationError)
            }
        }
    }
}

@Suite("Remote client answers")
struct RemoteAnswerTests {

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://127.0.0.1/rest/ping")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func envelope(_ fields: String) -> Data {
        Data(#"{"subsonic-response":{"version":"1.16.1","serverVersion":"2.0",\#(fields)}}"#.utf8)
    }

    @Test("The client and server agree on the protocol version")
    func versionsAgree() {
        #expect(RemoteLibraryClient.protocolVersion == SubsonicResponse.cadenceProtocolVersion)
    }

    @Test("A server on another protocol version is refused, even when it says ok")
    func versionMismatch() {
        #expect(throws: RemoteError.incompatibleServer(serverVersion: "2.0", protocolVersion: 2)) {
            try RemoteLibraryClient.checked(
                response(200), envelope(#""status":"ok","cadenceProtocolVersion":2"#))
        }
    }

    @Test("Protocol errors map to what the app can act on")
    func errorCodes() {
        func code(_ number: Int) -> RemoteError {
            do {
                _ = try RemoteLibraryClient.checked(response(200), envelope(
                    #""status":"failed","cadenceProtocolVersion":1,"error":{"code":\#(number),"message":"m"}"#))
                return .invalidResponse
            } catch {
                return error as? RemoteError ?? .invalidResponse
            }
        }
        #expect(code(42) == .notPaired)
        #expect(code(43) == .notPaired)
        #expect(code(44) == .notPaired)
        #expect(code(70) == .notFound)
        #expect(code(10) == .server(code: 10, message: "m"))
    }

    @Test("Too many requests says how long to wait")
    func busy() {
        #expect(RemoteLibraryClient.failure(response(429, headers: ["Retry-After": "7"]),
                                            body: Data()) == .busy(retryAfter: 7))
        #expect(RemoteLibraryClient.failure(response(429), body: Data()) == .busy(retryAfter: 1))
    }

    @Test("Something that is not an envelope is an invalid response")
    func garbage() {
        #expect(throws: RemoteError.invalidResponse) {
            try RemoteLibraryClient.checked(response(200), Data("<html>".utf8))
        }
        #expect(RemoteLibraryClient.failure(response(500), body: Data()) == .invalidResponse)
    }

    @Test("An IPv6 address is bracketed in the URL")
    func ipv6() {
        let server = RemoteServer(host: "fe80::1", port: 4533, fingerprint: "", name: "")
        #expect(server.baseURL?.absoluteString == "https://[fe80::1]:4533")
        let named = RemoteServer(host: "studio-mac.local", port: 4533, fingerprint: "", name: "")
        #expect(named.baseURL?.absoluteString == "https://studio-mac.local:4533")
    }
}

// MARK: - Background downloads

@Suite("Background downloads", .serialized)
struct RemoteBackgroundDownloadsTests {

    private func scratchFolder() -> RemoteDownloads {
        RemoteDownloads(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-background-\(UUID().uuidString)"))
    }

    /// The same delegate code as the app's background session, on an
    /// ephemeral session the tests can run.
    private func downloads(_ folder: RemoteDownloads, fingerprint: String) -> RemoteBackgroundDownloads {
        RemoteBackgroundDownloads(identifier: "test", fingerprint: fingerprint, folder: folder,
                                  configuration: .ephemeral)
    }

    private func next(_ events: AsyncStream<RemoteBackgroundDownloads.Event>) async -> RemoteBackgroundDownloads.Event? {
        var iterator = events.makeAsyncIterator()
        return await iterator.next()
    }

    @Test("A song downloads with a token, into the kept folder, and the request has no key")
    func downloadsWithToken() async throws {
        try await withServer { server in
            let client = try await server.pair()
            let song = try #require(try await client.search("morning").song.first)
            let token = try await client.downloadToken(songID: song.id)
            #expect(token.expiryDate.map { $0 > Date() } == true)

            let request = try client.downloadRequest(songID: song.id, token: token.token)
            let query = request.url?.query ?? ""
            #expect(!query.contains("apiKey"))
            #expect(!query.contains(client.credentials.apiKey))
            #expect(query.contains("token="))

            let folder = scratchFolder()
            defer { folder.removeAll() }
            let background = downloads(folder, fingerprint: server.identity.fingerprint)
            defer { background.invalidate() }
            let events = background.events()
            await background.start(songID: song.id, suffix: song.suffix ?? "", request: request)
            #expect(await next(events) == .kept(songID: song.id))

            let kept = try #require(folder.file(for: RemoteTrackLocation.url(songID: song.id, suffix: song.suffix)))
            #expect(try Data(contentsOf: kept) == server.audio)
        }
    }

    @Test("A refused token asks for a new one")
    func refusedToken() async throws {
        try await withServer { server in
            let client = try await server.pair()
            let song = try #require(try await client.search("morning").song.first)
            let request = try client.downloadRequest(songID: song.id, token: "v1.forged")
            let folder = scratchFolder()
            defer { folder.removeAll() }
            let background = downloads(folder, fingerprint: server.identity.fingerprint)
            defer { background.invalidate() }
            let events = background.events()
            await background.start(songID: song.id, suffix: song.suffix ?? "", request: request)
            #expect(await next(events) == .needsToken(songID: song.id))
            #expect(folder.songIDs().isEmpty)
        }
    }

    @Test("Another certificate is refused before anything is sent")
    func pinned() async throws {
        try await withServer { server in
            let client = try await server.pair()
            let song = try #require(try await client.search("morning").song.first)
            let token = try await client.downloadToken(songID: song.id)
            let request = try client.downloadRequest(songID: song.id, token: token.token)
            let folder = scratchFolder()
            defer { folder.removeAll() }
            let background = downloads(folder, fingerprint: String(repeating: "0", count: 64))
            defer { background.invalidate() }
            let events = background.events()
            await background.start(songID: song.id, suffix: song.suffix ?? "", request: request)
            #expect(await next(events) == .failed(songID: song.id, .untrustedServer))
            #expect(folder.songIDs().isEmpty)
        }
    }

    @Test("Task descriptions carry the song and its suffix")
    func descriptions() {
        let text = RemoteBackgroundDownloads.describe(songID: "tr-1", suffix: "flac")
        #expect(RemoteBackgroundDownloads.parse(text)?.songID == "tr-1")
        #expect(RemoteBackgroundDownloads.parse(text)?.suffix == "flac")
        #expect(RemoteBackgroundDownloads.parse("tr-1|")?.suffix == "")
        #expect(RemoteBackgroundDownloads.parse("nonsense") == nil)
        #expect(RemoteBackgroundDownloads.parse("|flac") == nil)
    }

    @Test("A file that is an error envelope never reaches the kept folder")
    func envelopes() throws {
        let folder = scratchFolder()
        defer { folder.removeAll() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(#"{"subsonic-response":{"status":"failed","error":{"code":70,"message":"x"}}}"#.utf8)
            .write(to: file)
        let response = HTTPURLResponse(url: URL(string: "https://mac.local/rest/download")!, statusCode: 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        let event = RemoteBackgroundDownloads.finish(file, response: response,
                                                     description: "tr-1|flac", into: folder)
        #expect(event == .failed(songID: "tr-1", .notFound))
        #expect(folder.songIDs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
