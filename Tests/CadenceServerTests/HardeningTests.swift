import Testing
import Foundation
import CadenceCore
import CadenceLibrary
@testable import CadenceServer

/// A clock a test can move.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@Suite("Failure throttle")
struct FailureThrottleTests {

    private func make(_ clock: Clock, capacity: Int = 1024) -> FailureThrottle {
        FailureThrottle(limit: 3, window: 60, block: 120, capacity: capacity, now: { clock.now })
    }

    @Test("An address is blocked at the limit, for the block's length, then starts clean")
    func blockAndRelease() {
        let clock = Clock()
        let throttle = make(clock)
        throttle.recordFailure("10.0.0.5")
        throttle.recordFailure("10.0.0.5")
        #expect(throttle.secondsBlocked("10.0.0.5") == nil)
        throttle.recordFailure("10.0.0.5")
        #expect(throttle.secondsBlocked("10.0.0.5") == 120)

        clock.advance(119)
        #expect(throttle.secondsBlocked("10.0.0.5") == 1)
        clock.advance(1)
        #expect(throttle.secondsBlocked("10.0.0.5") == nil)

        // Not one failure from the next block: the record was cleared.
        throttle.recordFailure("10.0.0.5")
        throttle.recordFailure("10.0.0.5")
        #expect(throttle.secondsBlocked("10.0.0.5") == nil)
    }

    @Test("Failures spread wider than the window do not add up")
    func window() {
        let clock = Clock()
        let throttle = make(clock)
        for _ in 0..<10 {
            throttle.recordFailure("10.0.0.5")
            clock.advance(40)
        }
        #expect(throttle.secondsBlocked("10.0.0.5") == nil)
    }

    @Test("One address being blocked does not block another")
    func separateAddresses() {
        let clock = Clock()
        let throttle = make(clock)
        for _ in 0..<3 { throttle.recordFailure("10.0.0.5") }
        throttle.recordFailure("10.0.0.6")
        #expect(throttle.secondsBlocked("10.0.0.5") != nil)
        #expect(throttle.secondsBlocked("10.0.0.6") == nil)
        #expect(throttle.secondsBlocked("10.0.0.7") == nil)
    }

    @Test("The table of addresses cannot grow without end")
    func capacity() {
        let clock = Clock()
        let throttle = make(clock, capacity: 50)
        for index in 0..<5000 {
            throttle.recordFailure("10.\(index / 250).\(index % 250).1")
            clock.advance(0.001)
        }
        #expect(throttle.trackedAddressCount <= 50)
    }
}

/// A server with paired devices and a movable clock.
private struct Fixture {
    let clock = Clock()
    let library: TestLibrary
    let server: LibraryServer
    let songID: String
    let fileURL: URL

    init(streamsPerDevice: Int = 2, fileBytes: Int = 4096) async throws {
        library = try await TestLibrary()
        let music = library.directory.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        fileURL = music.appendingPathComponent("track.flac")
        try Data(repeating: 0x5A, count: fileBytes).write(to: fileURL)
        let track = Track(url: fileURL, title: "Track", artist: "Artist", albumTitle: "Album",
                          duration: 100)
        try await library.store.upsert([track])
        songID = "tr-" + track.id.uuidString.lowercased()

        let clock = clock
        var configuration = LibraryServer.Configuration(serverVersion: "1")
        configuration.failureLimit = 3
        configuration.failureWindow = 60
        configuration.blockDuration = 120
        configuration.streamsPerDevice = streamsPerDevice
        configuration.now = { clock.now }
        server = LibraryServer(
            configuration: configuration,
            authenticator: FixedKeyAuthenticator(key: TestLibrary.key, deviceID: Self.device),
            library: library.store)
    }

    static let device = UUID()

    func get(_ endpoint: String, key: String? = TestLibrary.key, from address: String? = "10.0.0.5",
             extra: [(String, String)] = []) async -> HTTPResponse {
        var query = extra.map { (name: $0.0, value: $0.1) }
        if let key { query.append((name: "apiKey", value: key)) }
        return await server.respond(to: HTTPRequest(
            method: .get, path: "/rest/\(endpoint)", query: query, remoteAddress: address))
    }

    func stream() async -> HTTPResponse { await get("stream", extra: [("id", songID)]) }
}

@Suite("Rate limiting failed authentication")
struct AuthRateLimitTests {

    @Test("After too many wrong keys an address is refused, right key or not")
    func blocked() async throws {
        let fixture = try await Fixture()
        for _ in 0..<3 {
            #expect(await fixture.get("ping", key: "wrong").errorCode == 44)
        }
        let withWrongKey = await fixture.get("ping", key: "wrong")
        let withRightKey = await fixture.get("ping")
        for response in [withWrongKey, withRightKey] {
            #expect(response.status == .tooManyRequests)
            #expect(response.headers.first { $0.name == "Retry-After" }?.value == "120")
            #expect(response.body.isEmpty)
        }
    }

    @Test("The block lifts when its time is up")
    func lifts() async throws {
        let fixture = try await Fixture()
        for _ in 0..<3 { _ = await fixture.get("ping", key: "wrong") }
        fixture.clock.advance(119)
        #expect(await fixture.get("ping").status == .tooManyRequests)
        fixture.clock.advance(1)
        #expect(await fixture.get("ping").isOK)
    }

    @Test("Another address is not affected")
    func otherAddress() async throws {
        let fixture = try await Fixture()
        for _ in 0..<3 { _ = await fixture.get("ping", key: "wrong") }
        #expect(await fixture.get("ping", from: "10.0.0.6").isOK)
    }

    @Test("A missing key counts as a failure too")
    func missingKey() async throws {
        let fixture = try await Fixture()
        for _ in 0..<3 { _ = await fixture.get("ping", key: nil) }
        #expect(await fixture.get("ping").status == .tooManyRequests)
    }

    @Test("Successful requests are never counted")
    func successesFree() async throws {
        let fixture = try await Fixture()
        for _ in 0..<200 { #expect(await fixture.get("ping").isOK) }
        // Nor do requests to the one endpoint that needs no key.
        for _ in 0..<20 { _ = await fixture.get("getOpenSubsonicExtensions", key: nil) }
        #expect(await fixture.get("ping").isOK)
    }

    @Test("Errors after a valid key, such as an unknown id, are not failures to sign in")
    func notFoundIsNotAFailure() async throws {
        let fixture = try await Fixture()
        for _ in 0..<20 {
            #expect(await fixture.get("getSong", extra: [("id", "nonsense")]).errorCode == 70)
        }
        #expect(await fixture.get("ping").isOK)
    }

    @Test("A header claiming another address changes nothing")
    func forwardedHeaderIgnored() async throws {
        let fixture = try await Fixture()
        for index in 0..<3 {
            _ = await fixture.server.respond(to: HTTPRequest(
                method: .get, path: "/rest/ping", query: [(name: "apiKey", value: "wrong")],
                headers: ["x-forwarded-for": "192.168.9.\(index)", "x-real-ip": "192.168.9.\(index)"],
                remoteAddress: "10.0.0.5"))
        }
        #expect(await fixture.get("ping").status == .tooManyRequests)
    }

    @Test("Refused pairing attempts count, and a blocked address cannot pair")
    func pairing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-hardening-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let devices = try PairedDeviceStore(
            fileURL: directory.appendingPathComponent("paired-devices.json"))
        let pairing = PairingSession(devices: devices, maximumAttempts: 100)
        let library = try await TestLibrary()
        var configuration = LibraryServer.Configuration(serverVersion: "1")
        configuration.failureLimit = 3
        let server = LibraryServer(configuration: configuration, authenticator: devices,
                                   library: library.store, pairing: pairing)
        let code = await pairing.begin()

        func pair(_ token: String) async -> HTTPResponse {
            await server.respond(to: HTTPRequest(
                method: .post, path: "/pair", headers: ["content-type": "application/json"],
                body: Data(#"{"token":"\#(token)","name":"x"}"#.utf8), remoteAddress: "10.0.0.5"))
        }
        for _ in 0..<3 { #expect(await pair("wrong").status == .forbidden) }
        // The real token, from the blocked address: refused unread.
        #expect(await pair(code.token).status == .tooManyRequests)
        #expect(await devices.all().isEmpty)
        #expect(await pairing.current() == code)
    }

    @Test("A request with no known address is served and never counted")
    func noAddress() async throws {
        let fixture = try await Fixture()
        for _ in 0..<20 { _ = await fixture.get("ping", key: "wrong", from: nil) }
        #expect(await fixture.get("ping", from: nil).isOK)
    }
}

@Suite("Stream limit per device")
struct StreamLimitTests {

    @Test("A device gets its limit of streams, and the next is refused until one ends")
    func limit() async throws {
        let fixture = try await Fixture(streamsPerDevice: 2)
        let first = await fixture.stream()
        let second = await fixture.stream()
        #expect(first.status == .ok)
        #expect(second.status == .ok)
        #expect(fixture.server.streams.activeCount(Fixture.device) == 2)

        let third = await fixture.stream()
        #expect(third.status == .tooManyRequests)
        #expect(third.file == nil)
        #expect(third.headers.first { $0.name == "Retry-After" } != nil)

        first.onFinish?()
        #expect(fixture.server.streams.activeCount(Fixture.device) == 1)
        #expect(await fixture.stream().status == .ok)
    }

    @Test("Browsing is not limited while streams are in use")
    func browsingUnaffected() async throws {
        let fixture = try await Fixture(streamsPerDevice: 1)
        _ = await fixture.stream()
        #expect(await fixture.stream().status == .tooManyRequests)
        #expect(await fixture.get("ping").isOK)
        #expect(await fixture.get("getArtists").isOK)
    }

    @Test("A request that sends no file takes no place")
    func noFileNoSlot() async throws {
        let fixture = try await Fixture(streamsPerDevice: 1)
        // Unknown song, missing id, and a range outside the file.
        _ = await fixture.get("stream", extra: [("id", "nonsense")])
        _ = await fixture.get("stream")
        let beyond = await fixture.server.respond(to: HTTPRequest(
            method: .get, path: "/rest/stream",
            query: [(name: "id", value: fixture.songID), (name: "apiKey", value: TestLibrary.key)],
            headers: ["range": "bytes=999999-"]))
        #expect(beyond.status == .rangeNotSatisfiable)
        #expect(beyond.onFinish == nil)
        #expect(fixture.server.streams.activeCount(Fixture.device) == 0)
        #expect(await fixture.stream().status == .ok)
    }

    @Test("A refused stream is not a failed sign-in")
    func refusalNotCounted() async throws {
        let fixture = try await Fixture(streamsPerDevice: 1)
        _ = await fixture.stream()
        for _ in 0..<20 { #expect(await fixture.stream().status == .tooManyRequests) }
        #expect(await fixture.get("ping").isOK)
    }
}

/// Reads a stream to its end on another thread. The stream is used by one
/// thread at a time: the test stops touching it before handing it over.
private final class Drain: @unchecked Sendable {
    private let stream: InputStream
    init(_ stream: InputStream) { self.stream = stream }

    func readToEnd() -> Int {
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            count += read
        }
        return count
    }
}

/// Over a socket: the listener gives places back, and drops a reader that stalls.
@Suite("Stream limits over a socket", .serialized)
struct StreamSocketTests {

    private func url(_ port: UInt16, _ fixture: Fixture) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/rest/stream"
        components.queryItems = [.init(name: "id", value: fixture.songID),
                                 .init(name: "apiKey", value: TestLibrary.key)]
        return try #require(components.url)
    }

    /// Waits, briefly, for the listener to finish closing a connection.
    private func settled(_ fixture: Fixture) async throws -> Int {
        for _ in 0..<100 {
            if fixture.server.streams.activeCount(Fixture.device) == 0 { return 0 }
            try await Task.sleep(for: .milliseconds(20))
        }
        return fixture.server.streams.activeCount(Fixture.device)
    }

    @Test("A stream that completes gives its place back")
    func completedStreamReleases() async throws {
        let fixture = try await Fixture(streamsPerDevice: 1, fileBytes: 200_000)
        let server = fixture.server
        let listener = try HTTPListener.loopback { await server.respond(to: $0) }
        let port = try await listener.start()
        defer { listener.stop() }
        let session = URLSession(configuration: .ephemeral)

        // With a limit of one, five in a row only work if each is released.
        for _ in 0..<5 {
            let (data, response) = try await session.data(from: try url(port, fixture))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(data.count == 200_000)
            #expect(try await settled(fixture) == 0)
        }
    }

    @Test("HEAD, which sends no body, also gives its place back")
    func headReleases() async throws {
        let fixture = try await Fixture(streamsPerDevice: 1)
        let server = fixture.server
        let listener = try HTTPListener.loopback { await server.respond(to: $0) }
        let port = try await listener.start()
        defer { listener.stop() }
        var request = URLRequest(url: try url(port, fixture))
        request.httpMethod = "HEAD"
        for _ in 0..<3 {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(try await settled(fixture) == 0)
        }
    }

    @Test("The address the listener reports is the socket's, and it is rate limited")
    func listenerSuppliesAddress() async throws {
        let fixture = try await Fixture()
        let server = fixture.server
        let listener = try HTTPListener.loopback { await server.respond(to: $0) }
        let port = try await listener.start()
        defer { listener.stop() }
        let session = URLSession(configuration: .ephemeral)
        let wrong = try #require(URL(string: "http://127.0.0.1:\(port)/rest/ping?apiKey=wrong"))
        var statuses: [Int] = []
        for _ in 0..<5 {
            let (_, response) = try await session.data(from: wrong)
            statuses.append((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // Three failures are answered; from the fourth the address is blocked.
        #expect(statuses == [200, 200, 200, 429, 429])
    }

    /// A client asks for a large file and reads nothing. The server must not
    /// wait for ever: it closes the connection and frees the place.
    @Test("A client that stops reading is dropped, and its place freed")
    func stalledReader() async throws {
        // Far more than socket buffers hold, so the server really is waiting.
        let fixture = try await Fixture(streamsPerDevice: 1, fileBytes: 64 * 1024 * 1024)
        let server = fixture.server
        var limits = HTTPListener.Limits()
        limits.stallTimeout = 0.5
        let listener = try HTTPListener.loopback(limits: limits) { await server.respond(to: $0) }
        let port = try await listener.start()
        defer { listener.stop() }

        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: "127.0.0.1", port: Int(port),
                                inputStream: &input, outputStream: &output)
        let reader = try #require(input)
        let writer = try #require(output)
        reader.open()
        writer.open()
        defer { reader.close(); writer.close() }
        let path = try url(port, fixture)
        let request = Array("GET \(path.path)?\(path.query ?? "") HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        #expect(writer.write(request, maxLength: request.count) == request.count)

        // Read nothing. The stream is taken, then given back when the server
        // gives up on us.
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.server.streams.activeCount(Fixture.device) == 1)
        try await Task.sleep(for: .seconds(2))
        #expect(fixture.server.streams.activeCount(Fixture.device) == 0)

        // What did arrive is less than the file: the server stopped sending.
        let drain = Drain(reader)
        let total = await Task.detached { drain.readToEnd() }.value
        #expect(total < 64 * 1024 * 1024)

        // And the place is usable again.
        let (_, response) = try await URLSession(configuration: .ephemeral)
            .data(from: try #require(URL(string: "http://127.0.0.1:\(port)/rest/ping?apiKey=\(TestLibrary.key)")))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
