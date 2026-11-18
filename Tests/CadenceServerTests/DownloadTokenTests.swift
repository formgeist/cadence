import Testing
import Foundation
import CryptoKit
import CadenceServer

@Suite("Download tokens")
struct DownloadTokenTests {

    private let device = UUID()
    private let song = "tr-" + UUID().uuidString.lowercased()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A token works for its song, device and lifetime, and nothing else")
    func roundTrip() {
        let tokens = DownloadTokens(lifetime: 3600)
        let issued = tokens.issue(songID: song, device: device, now: now)
        #expect(issued.expires == now.addingTimeInterval(3600))
        #expect(tokens.verify(issued.token, songID: song, now: now) == device)
        #expect(tokens.verify(issued.token, songID: song, now: now.addingTimeInterval(3599)) == device)

        // Expired, another song, or another server's secret.
        #expect(tokens.verify(issued.token, songID: song, now: now.addingTimeInterval(3600)) == nil)
        #expect(tokens.verify(issued.token, songID: "tr-other", now: now) == nil)
        #expect(DownloadTokens(lifetime: 3600).verify(issued.token, songID: song, now: now) == nil)
    }

    @Test("A changed token is refused")
    func tampering() {
        let tokens = DownloadTokens()
        let token = tokens.issue(songID: song, device: device, now: now).token
        var parts = token.split(separator: ".").map(String.init)

        // A later expiry, or another device, breaks the MAC.
        parts[2] = String(Int(parts[2])! + 86_400)
        #expect(tokens.verify(parts.joined(separator: "."), songID: song, now: now) == nil)
        parts = token.split(separator: ".").map(String.init)
        parts[1] = UUID().uuidString.lowercased()
        #expect(tokens.verify(parts.joined(separator: "."), songID: song, now: now) == nil)

        for garbage in ["", "v1", "v2.a.b.c", "v1.\(device.uuidString).x.y", token + ".extra",
                        "v1.\(device.uuidString).9999999999.\(String(repeating: "A", count: 200))"] {
            #expect(tokens.verify(garbage, songID: song, now: now) == nil)
        }
    }
}

@Suite("Downloading with a token")
struct DownloadTokenServerTests {

    private func server(_ fixture: MediaFixture, lifetime: TimeInterval = 3600,
                        failureLimit: Int = 10, now: @escaping @Sendable () -> Date = Date.init,
                        authenticator: (any Authenticator)? = nil) -> LibraryServer {
        var configuration = LibraryServer.Configuration(serverVersion: "1.0")
        configuration.downloadTokenLifetime = lifetime
        configuration.failureLimit = failureLimit
        configuration.now = now
        return LibraryServer(configuration: configuration,
                             authenticator: authenticator ?? FixedKeyAuthenticator(key: TestLibrary.key),
                             library: fixture.library.store)
    }

    private func get(_ server: LibraryServer, _ endpoint: String, _ query: [(String, String)],
                     address: String? = nil) async -> HTTPResponse {
        await server.respond(to: HTTPRequest(
            method: .get, path: "/rest/\(endpoint)",
            query: query.map { (name: $0.0, value: $0.1) }, remoteAddress: address))
    }

    private func token(_ server: LibraryServer, _ songID: String, key: String = TestLibrary.key) async -> String? {
        let response = await get(server, "getDownloadToken", [("id", songID), ("apiKey", key)])
        return response.object("downloadToken")["token"] as? String
    }

    @Test("A token is issued for a song with the key, and says when it ends")
    func issue() async throws {
        let fixture = try await MediaFixture()
        let server = server(fixture)
        let response = await get(server, "getDownloadToken", [("id", fixture.songID), ("apiKey", TestLibrary.key)])
        #expect(response.isOK)
        let issued = response.object("downloadToken")
        #expect((issued["token"] as? String)?.hasPrefix("v1.") == true)
        #expect((issued["expires"] as? String).flatMap { try? Date($0, strategy: .iso8601) } != nil)

        #expect(await get(server, "getDownloadToken", [("id", fixture.songID)]).errorCode == 44)
        let unknown = "tr-" + UUID().uuidString.lowercased()
        #expect(await get(server, "getDownloadToken", [("id", unknown), ("apiKey", TestLibrary.key)])
            .errorCode == 70)
    }

    @Test("download sends the file for a token, without the key")
    func download() async throws {
        let fixture = try await MediaFixture()
        let server = server(fixture)
        let token = try #require(await token(server, fixture.songID))
        let response = await get(server, "download", [("id", fixture.songID), ("token", token)])
        #expect(response.status == .ok)
        #expect(response.file == FileBody(url: fixture.fileURL, offset: 0, length: 300_000))
    }

    @Test("A token opens download alone, and only its own song")
    func scope() async throws {
        let fixture = try await MediaFixture()
        let server = server(fixture)
        let token = try #require(await token(server, fixture.songID))

        for endpoint in ["stream", "getSong", "getDownloadToken", "getAlbumList2"] {
            let response = await get(server, endpoint, [("id", fixture.songID), ("token", token)])
            #expect(response.errorCode == 44, "\(endpoint) took a token")
            #expect(response.file == nil)
        }
        let other = "tr-" + UUID().uuidString.lowercased()
        let wrongSong = await get(server, "download", [("id", other), ("token", token)])
        #expect(wrongSong.errorCode == 50)
        #expect(wrongSong.file == nil)
    }

    @Test("An expired token is refused")
    func expiry() async throws {
        let fixture = try await MediaFixture()
        let clock = Clock(Date())
        let server = server(fixture, lifetime: 60, now: { clock.now })
        let token = try #require(await token(server, fixture.songID))
        clock.now = clock.now.addingTimeInterval(61)
        let response = await get(server, "download", [("id", fixture.songID), ("token", token)])
        #expect(response.errorCode == 50)
        #expect(response.file == nil)
    }

    @Test("A revoked device's tokens stop working")
    func revoked() async throws {
        let fixture = try await MediaFixture()
        let folder = fixture.library.directory.appendingPathComponent("devices")
        let devices = try PairedDeviceStore(fileURL: folder.appendingPathComponent("paired.json"))
        let (device, key) = try await devices.pair(named: "Phone")
        let server = server(fixture, authenticator: devices)
        let token = try #require(await token(server, fixture.songID, key: key))
        #expect(await get(server, "download", [("id", fixture.songID), ("token", token)]).status == .ok)

        try await devices.revoke(device.id)
        let response = await get(server, "download", [("id", fixture.songID), ("token", token)])
        #expect(response.errorCode == 50)
        #expect(response.file == nil)
    }

    @Test("Wrong tokens count as failed sign-ins")
    func throttled() async throws {
        let fixture = try await MediaFixture()
        let server = server(fixture, failureLimit: 3)
        for _ in 0..<3 {
            _ = await get(server, "download", [("id", fixture.songID), ("token", "v1.nope")],
                          address: "10.0.0.9")
        }
        let blocked = await get(server, "download", [("id", fixture.songID), ("apiKey", TestLibrary.key)],
                                address: "10.0.0.9")
        #expect(blocked.status == .tooManyRequests)
    }

    @Test("The server says it offers download tokens")
    func advertised() async throws {
        let fixture = try await MediaFixture()
        let response = await get(server(fixture), "getOpenSubsonicExtensions", [])
        let names = (response.envelope["openSubsonicExtensions"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        #expect(names.contains("cadenceDownloadTokens"))
    }
}

/// A clock a test moves by hand.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
