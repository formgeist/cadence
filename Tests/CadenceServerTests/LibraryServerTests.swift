import Testing
import Foundation
import CadenceServer

/// A key made for this test run. No key is written down anywhere.
private let key = UUID().uuidString + UUID().uuidString

private let server = LibraryServer(
    configuration: .init(serverVersion: "9.8.7"),
    authenticator: FixedKeyAuthenticator(key: key))

private func get(_ path: String, _ query: [(String, String)] = []) async -> HTTPResponse {
    await server.respond(to: HTTPRequest(
        method: .get, path: path, query: query.map { (name: $0.0, value: $0.1) }))
}

/// The `subsonic-response` object of a response.
private func envelope(_ response: HTTPResponse) throws -> [String: Any] {
    let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    return try #require(json?["subsonic-response"] as? [String: Any])
}

private func errorCode(_ response: HTTPResponse) throws -> Int? {
    (try envelope(response)["error"] as? [String: Any])?["code"] as? Int
}

@Suite("Library server")
struct LibraryServerTests {

    // MARK: ping

    @Test("ping with a valid key answers ok, with the versions a client checks")
    func ping() async throws {
        let response = await get("/rest/ping", [("apiKey", key), ("f", "json")])
        #expect(response.status == .ok)
        #expect(response.contentType == "application/json; charset=utf-8")

        let body = try envelope(response)
        #expect(body["status"] as? String == "ok")
        #expect(body["version"] as? String == "1.16.1")
        #expect(body["type"] as? String == "cadence")
        #expect(body["serverVersion"] as? String == "9.8.7")
        #expect(body["openSubsonic"] as? Bool == true)
        #expect(body["cadenceProtocolVersion"] as? Int == 1)
        #expect(body["error"] == nil)
    }

    @Test("The .view suffix names the same endpoint")
    func viewSuffix() async throws {
        let response = await get("/rest/ping.view", [("apiKey", key)])
        #expect(try envelope(response)["status"] as? String == "ok")
    }

    // MARK: Authentication

    @Test("No key and a wrong key get the same refusal")
    func missingAndWrongKey() async throws {
        let missing = await get("/rest/ping")
        let wrong = await get("/rest/ping", [("apiKey", "not-the-key")])
        let empty = await get("/rest/ping", [("apiKey", "")])
        for response in [missing, wrong, empty] {
            // A protocol failure is HTTP 200 with the error inside.
            #expect(response.status == .ok)
            #expect(try envelope(response)["status"] as? String == "failed")
            #expect(try errorCode(response) == 44)
        }
        #expect(missing.body == wrong.body)
    }

    @Test("A key that only shares a prefix with the real one is refused")
    func prefixKey() async throws {
        let response = await get("/rest/ping", [("apiKey", String(key.dropLast()))])
        #expect(try errorCode(response) == 44)
    }

    @Test("A user name and password are refused as a mechanism, not checked")
    func legacyCredentials() async throws {
        let password = await get("/rest/ping", [("u", "admin"), ("p", "admin")])
        #expect(try errorCode(password) == 42)
        let token = await get("/rest/ping", [("u", "admin"), ("t", "abc"), ("s", "salt")])
        #expect(try errorCode(token) == 42)
    }

    @Test("A valid key sent alongside a user name is refused")
    func conflictingCredentials() async throws {
        let response = await get("/rest/ping", [("apiKey", key), ("u", "admin")])
        #expect(try errorCode(response) == 43)
    }

    @Test("A refusal never repeats the key it was sent")
    func refusalDoesNotEchoKey() async throws {
        let attempt = "attempted-key-\(UUID().uuidString)"
        let response = await get("/rest/ping", [("apiKey", attempt)])
        #expect(!String(decoding: response.body, as: UTF8.self).contains(attempt))
    }

    // MARK: getOpenSubsonicExtensions

    @Test("Extensions are readable without a key, and name API-key authentication")
    func extensions() async throws {
        let response = await get("/rest/getOpenSubsonicExtensions")
        let body = try envelope(response)
        #expect(body["status"] as? String == "ok")
        let extensions = try #require(body["openSubsonicExtensions"] as? [[String: Any]])
        #expect(extensions.count == 1)
        #expect(extensions[0]["name"] as? String == "apiKeyAuthentication")
        #expect(extensions[0]["versions"] as? [Int] == [1])
    }

    // MARK: Routing

    @Test("An endpoint that does not exist is a 404 with a failed envelope")
    func unknownEndpoint() async throws {
        let response = await get("/rest/deleteEverything", [("apiKey", key)])
        #expect(response.status == .notFound)
        #expect(try errorCode(response) == 0)
    }

    @Test("No write endpoint of the Subsonic API is routed", arguments: [
        "createPlaylist", "updatePlaylist", "deletePlaylist", "star", "unstar",
        "setRating", "scrobble", "startScan", "createUser", "deleteUser",
        "updateUser", "changePassword", "createShare", "savePlayQueue",
    ])
    func noWriteEndpoints(name: String) async {
        #expect(await get("/rest/\(name)", [("apiKey", key)]).status == .notFound)
        #expect(await get("/rest/\(name).view", [("apiKey", key)]).status == .notFound)
    }

    @Test("Paths outside /rest, and paths that only resemble a route, find nothing", arguments: [
        "/", "/rest", "/rest/", "/ping", "/rest/ping/", "/rest/ping/extra",
        "/rest/../rest/ping", "/rest//ping", "/REST/ping", "/rest/Ping",
        "/rest/ping.view.view", "/rest/../../etc/passwd", "/etc/passwd",
    ])
    func otherPaths(path: String) async {
        #expect(await get(path, [("apiKey", key)]).status == .notFound)
    }

    // MARK: Envelope

    @Test("The same answer is the same bytes every time")
    func deterministic() async {
        let first = await get("/rest/ping", [("apiKey", key)])
        let second = await get("/rest/ping", [("apiKey", key)])
        #expect(first.body == second.body)
    }
}

@Suite("HTTP response")
struct HTTPResponseTests {

    @Test("A response is written with its length, and always closes")
    func serialized() {
        let response = HTTPResponse(status: .ok, contentType: "application/json",
                                    body: Data("{}".utf8))
        let text = String(decoding: response.serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.contains("Cache-Control: no-store\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }

    @Test("HEAD gets the same headers and no body")
    func head() {
        let response = HTTPResponse(status: .ok, body: Data("{}".utf8))
        let text = String(decoding: response.serialized(includingBody: false), as: UTF8.self)
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }
}
