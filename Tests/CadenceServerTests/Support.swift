import Foundation
import CadenceCore
import CadenceLibrary
import CadenceServer

/// A store on a temporary database, removed when the value goes away.
final class TestLibrary: Sendable {
    let store: SQLiteLibraryStore
    let artwork: DiskArtworkStore
    /// A folder for the test's own files, removed with the library.
    let directory: URL

    init(_ tracks: [Track] = []) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-server-\(UUID().uuidString)")
        store = try SQLiteLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        artwork = try DiskArtworkStore(root: directory.appendingPathComponent("art"))
        try await store.upsert(tracks)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A key made for this test run. No key is written down anywhere.
    static let key = UUID().uuidString + UUID().uuidString

    func server(version: String = "9.8.7") -> TestServer {
        TestServer(library: self, server: LibraryServer(
            configuration: .init(serverVersion: version),
            authenticator: FixedKeyAuthenticator(key: Self.key),
            library: store, artwork: artwork))
    }
}

/// A server together with the library it reads. Holding the library here is
/// what keeps the temporary database on disk for as long as the server is in
/// use: `try await TestLibrary(tracks).server()` would otherwise delete it
/// before the first request.
struct TestServer: Sendable {
    let library: TestLibrary
    let server: LibraryServer

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        await server.respond(to: request)
    }
}

extension TestServer {
    /// A GET with the test key attached.
    func get(_ endpoint: String, _ query: [(String, String)] = [],
             authenticated: Bool = true, headers: [String: String] = [:]) async -> HTTPResponse {
        var parameters = query.map { (name: $0.0, value: $0.1) }
        if authenticated { parameters.append((name: "apiKey", value: TestLibrary.key)) }
        return await respond(to: HTTPRequest(
            method: .get, path: endpoint.hasPrefix("/") ? endpoint : "/rest/\(endpoint)",
            query: parameters, headers: headers))
    }
}

extension HTTPResponse {
    /// The `subsonic-response` object.
    var envelope: [String: Any] {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return json?["subsonic-response"] as? [String: Any] ?? [:]
    }

    var isOK: Bool { envelope["status"] as? String == "ok" }
    var errorCode: Int? { (envelope["error"] as? [String: Any])?["code"] as? Int }
    var text: String { String(decoding: body, as: UTF8.self) }

    func object(_ key: String) -> [String: Any] { envelope[key] as? [String: Any] ?? [:] }
}
