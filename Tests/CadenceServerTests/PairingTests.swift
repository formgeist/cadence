import Testing
import Foundation
import CadenceLibrary
@testable import CadenceServer

/// A clock a test can move.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// A device store, a pairing session over it and a server over both.
private struct Fixture {
    let directory: URL
    let clock = Clock()
    let devices: PairedDeviceStore
    let pairing: PairingSession
    let library: TestLibrary
    let server: LibraryServer

    init(pairingEnabled: Bool = true) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-pairing-\(UUID().uuidString)")
        let clock = clock
        devices = try PairedDeviceStore(
            fileURL: directory.appendingPathComponent("paired-devices.json"),
            now: { clock.now })
        pairing = PairingSession(devices: devices, now: { clock.now })
        library = try await TestLibrary()
        server = LibraryServer(
            configuration: .init(serverVersion: "9.8.7"), authenticator: devices,
            library: library.store, pairing: pairingEnabled ? pairing : nil)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func post(_ body: String, contentType: String? = "application/json",
              path: String = "/pair") async -> HTTPResponse {
        var headers: [String: String] = [:]
        if let contentType { headers["content-type"] = contentType }
        return await server.respond(to: HTTPRequest(
            method: .post, path: path, headers: headers, body: Data(body.utf8)))
    }

    func pair(code: String, name: String = "iPhone") async -> HTTPResponse {
        await post(#"{"code":"\#(code)","name":"\#(name)"}"#)
    }

    func ping(_ key: String) async -> HTTPResponse {
        await server.respond(to: HTTPRequest(
            method: .get, path: "/rest/ping", query: [(name: "apiKey", value: key)]))
    }
}

private func json(_ response: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
}

/// A code that is certainly not `code`.
private func wrong(_ code: String) -> String {
    code == "000000" ? "000001" : "000000"
}

@Suite("Pairing codes")
struct PairingSessionTests {

    @Test("A code is six digits and lasts five minutes")
    func shape() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        #expect(code.digits.count == 6)
        #expect(code.digits.allSatisfy { $0.isASCII && $0.isNumber })
        #expect(code.expiresAt == fixture.clock.now.addingTimeInterval(300))
        #expect(await fixture.pairing.current() == code)
    }

    @Test("Codes are spread over the whole range, leading zeroes included")
    func distribution() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        var seen: Set<String> = []
        var firstDigits: Set<Character> = []
        for _ in 0..<400 {
            let digits = await fixture.pairing.begin().digits
            #expect(digits.count == 6)
            seen.insert(digits)
            firstDigits.insert(digits.first!)
        }
        // 400 draws from a million: repeats are possible but rare.
        #expect(seen.count > 390)
        // Every leading digit turns up, zero among them.
        #expect(firstDigits.count == 10)
    }

    @Test("The right code pairs a device, once")
    func redeemOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()

        let paired = try #require(await fixture.pairing.redeem(code: code.digits, deviceName: "iPhone"))
        #expect(await fixture.devices.device(forAPIKey: paired.apiKey) == paired.device.id)

        // The same code again is nothing.
        #expect(await fixture.pairing.redeem(code: code.digits, deviceName: "Second") == nil)
        #expect(await fixture.pairing.current() == nil)
        #expect(await fixture.devices.all().count == 1)
    }

    @Test("Many requests arriving together with the right code pair one device")
    func concurrentRedeem() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()

        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<24 {
                group.addTask {
                    await fixture.pairing.redeem(
                        code: code.digits, deviceName: "Device \(index)") != nil
                }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }
        #expect(successes == 1)
        #expect(await fixture.devices.all().count == 1)
    }

    @Test("With no code showing, nothing pairs")
    func closed() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        for guess in ["000000", "123456", "", "999999"] {
            #expect(await fixture.pairing.redeem(code: guess, deviceName: "x") == nil)
        }
        #expect(await fixture.devices.all().isEmpty)
    }

    @Test("A code stops working when it expires")
    func expiry() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()

        fixture.clock.advance(299)
        #expect(await fixture.pairing.current() == code)
        fixture.clock.advance(1)
        #expect(await fixture.pairing.current() == nil)
        #expect(await fixture.pairing.redeem(code: code.digits, deviceName: "Late") == nil)
        #expect(await fixture.devices.all().isEmpty)
    }

    @Test("Five wrong guesses cancel the code, even for the right one after")
    func attemptLimit() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        let bad = wrong(code.digits)

        for _ in 0..<4 {
            #expect(await fixture.pairing.redeem(code: bad, deviceName: "x") == nil)
            #expect(await fixture.pairing.current() == code)
        }
        #expect(await fixture.pairing.redeem(code: bad, deviceName: "x") == nil)
        #expect(await fixture.pairing.current() == nil)
        #expect(await fixture.pairing.redeem(code: code.digits, deviceName: "Too late") == nil)
        #expect(await fixture.devices.all().isEmpty)
    }

    @Test("Four wrong guesses and then the right one still pairs")
    func withinAttemptLimit() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        for _ in 0..<4 {
            _ = await fixture.pairing.redeem(code: wrong(code.digits), deviceName: "x")
        }
        #expect(await fixture.pairing.redeem(code: code.digits, deviceName: "iPhone") != nil)
    }

    @Test("Asking for a new code retires the old one and restores the attempts")
    func replace() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        var first = await fixture.pairing.begin()
        var second = await fixture.pairing.begin()
        // One time in a million the two are equal; draw again if so.
        while second.digits == first.digits {
            first = second
            second = await fixture.pairing.begin()
        }
        #expect(await fixture.pairing.redeem(code: first.digits, deviceName: "Old") == nil)
        #expect(await fixture.pairing.redeem(code: second.digits, deviceName: "New") != nil)
    }

    @Test("Cancelling closes pairing")
    func cancel() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        await fixture.pairing.cancel()
        #expect(await fixture.pairing.current() == nil)
        #expect(await fixture.pairing.redeem(code: code.digits, deviceName: "x") == nil)
    }

    @Test("Only the six digits themselves are the code", arguments: [
        " ", "x", "0", "１２３４５６",
    ])
    func nearCodes(suffix: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        #expect(await fixture.pairing.redeem(code: code.digits + suffix, deviceName: "x") == nil)
        #expect(await fixture.pairing.redeem(code: suffix + code.digits, deviceName: "x") == nil)
        #expect(await fixture.pairing.redeem(code: String(code.digits.dropLast()), deviceName: "x") == nil)
        #expect(await fixture.devices.all().isEmpty)
    }

    @Test("When no more devices can be paired, the code is spent and nothing pairs")
    func storeFull() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        for index in 0..<PairedDeviceStore.maximumDevices {
            _ = try await fixture.devices.pair(named: "Device \(index)")
        }
        let code = await fixture.pairing.begin()
        #expect(await fixture.pairing.redeem(code: code.digits, deviceName: "Extra") == nil)
        #expect(await fixture.devices.all().count == PairedDeviceStore.maximumDevices)
    }
}

@Suite("POST /pair")
struct PairingEndpointTests {

    @Test("A device that sends the code gets a key that works")
    func pairs() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()

        let response = await fixture.pair(code: code.digits, name: "Casper's iPhone")
        #expect(response.status == .ok)
        #expect(response.contentType == "application/json; charset=utf-8")
        let body = json(response)
        let key = try #require(body["apiKey"] as? String)
        #expect(key.count == 43)
        #expect(body["serverVersion"] as? String == "9.8.7")
        #expect(body["cadenceProtocolVersion"] as? Int == 1)

        let device = try #require(await fixture.devices.all().first)
        #expect(body["deviceId"] as? String == device.id.uuidString.lowercased())
        #expect(device.name == "Casper's iPhone")
        #expect(await fixture.ping(key).isOK)
    }

    @Test("Every refusal is the same answer")
    func uniformRefusal() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        // No code showing.
        let closed = await fixture.pair(code: "123456")

        // A wrong code.
        let code = await fixture.pairing.begin()
        let wrongCode = await fixture.pair(code: wrong(code.digits))

        // The right code, after it has expired.
        fixture.clock.advance(301)
        let expired = await fixture.pair(code: code.digits)

        // The right code, after it has been used.
        let fresh = await fixture.pairing.begin()
        _ = await fixture.pair(code: fresh.digits)
        let used = await fixture.pair(code: fresh.digits)

        for response in [closed, wrongCode, expired, used] {
            #expect(response.status == .forbidden)
            #expect(response == closed)
            #expect(json(response)["error"] as? String == "pairing_failed")
            #expect(json(response)["apiKey"] == nil)
        }
    }

    @Test("Guessing through the endpoint spends the attempts")
    func attemptLimit() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        for _ in 0..<5 {
            #expect(await fixture.pair(code: wrong(code.digits)).status == .forbidden)
        }
        #expect(await fixture.pair(code: code.digits).status == .forbidden)
        #expect(await fixture.devices.all().isEmpty)
    }

    @Test("A request that is not exactly a JSON pairing request is refused and costs nothing", arguments: [
        "", "not json", "[]", "{}", #"{"code":"123456"}"#, #"{"name":"iPhone"}"#,
        #"{"code":123456,"name":"iPhone"}"#, #"{"code":null,"name":"iPhone"}"#,
        #"{"code":"123456","name":["iPhone"]}"#, "{\"code\":\"123456\",\"name\":\"iPhone\"",
    ])
    func malformed(body: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        #expect(await fixture.post(body).status == .badRequest)
        // Not a guess, so not an attempt: the code still works.
        #expect(await fixture.pairing.current() == code)
        #expect(await fixture.devices.all().isEmpty)
    }

    @Test("The content type must be JSON", arguments: [
        "text/plain", "application/x-www-form-urlencoded", "multipart/form-data", "",
        "application/jsonp", "text/json",
    ])
    func contentType(type: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        let body = #"{"code":"\#(code.digits)","name":"iPhone"}"#
        #expect(await fixture.post(body, contentType: type).status == .unsupportedMediaType)
        #expect(await fixture.post(body, contentType: nil).status == .unsupportedMediaType)
        #expect(await fixture.devices.all().isEmpty)
        // With a charset it is still JSON.
        #expect(await fixture.post(body, contentType: "application/json; charset=utf-8").status == .ok)
    }

    @Test("Pairing is POST only")
    func methods() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        for method in [HTTPRequest.Method.get, .head] {
            let response = await fixture.server.respond(to: HTTPRequest(
                method: method, path: "/pair",
                query: [(name: "code", value: code.digits), (name: "name", value: "iPhone")]))
            #expect(response.status == .methodNotAllowed)
        }
        #expect(await fixture.devices.all().isEmpty)
        #expect(await fixture.pairing.current() == code)
    }

    @Test("POST reaches nothing but pairing", arguments: [
        "/rest/ping", "/rest/getArtists", "/rest/stream", "/rest/createPlaylist", "/", "/pair/",
        "/rest/pair", "/PAIR", "/pair.view",
    ])
    func postElsewhere(path: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        let response = await fixture.post(
            #"{"code":"\#(code.digits)","name":"iPhone"}"#, path: path)
        #expect(response.status == .methodNotAllowed)
        #expect(await fixture.devices.all().isEmpty)
    }

    @Test("A server built without pairing has no pairing endpoint")
    func disabled() async throws {
        let fixture = try await Fixture(pairingEnabled: false)
        defer { fixture.cleanUp() }
        #expect(await fixture.pair(code: "123456").status == .notFound)
    }

    @Test("A hostile device name is cleaned, not trusted")
    func hostileName() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let code = await fixture.pairing.begin()
        let name = String(repeating: "A", count: 400) + "\\n\\u0000<script>"
        #expect(await fixture.pair(code: code.digits, name: name).status == .ok)
        let kept = try #require(await fixture.devices.all().first?.name)
        #expect(kept.count == PairedDeviceStore.maximumNameLength)
        #expect(!kept.contains("\n"))
    }

    @Test("A paired device can be revoked, and pairing again gives a different key")
    func revokeAndRepair() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        var code = await fixture.pairing.begin()
        let firstKey = try #require(json(await fixture.pair(code: code.digits))["apiKey"] as? String)
        let device = try #require(await fixture.devices.all().first)

        try await fixture.devices.revoke(device.id)
        #expect(await fixture.ping(firstKey).errorCode == 44)

        code = await fixture.pairing.begin()
        let secondKey = try #require(json(await fixture.pair(code: code.digits))["apiKey"] as? String)
        #expect(secondKey != firstKey)
        #expect(await fixture.ping(secondKey).isOK)
        #expect(await fixture.ping(firstKey).errorCode == 44)
    }

    @Test("Pairing over a socket: the phone's request, start to finish")
    func overSocket() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let server = fixture.server
        let listener = try HTTPListener.loopback { await server.respond(to: $0) }
        let port = try await listener.start()
        defer { listener.stop() }
        let code = await fixture.pairing.begin()

        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/pair")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["code": code.digits, "name": "iPad"])
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let key = try #require(
            (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["apiKey"] as? String)
        #expect(await fixture.ping(key).isOK)

        // A body over the limit never reaches the endpoint.
        request.httpBody = Data(repeating: 0x20, count: 2000)
        let (_, tooLarge) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((tooLarge as? HTTPURLResponse)?.statusCode == 413)
    }
}
