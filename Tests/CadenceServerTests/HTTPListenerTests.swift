import Testing
import Foundation
import CadenceServer

/// The server over a real socket: listener, parser, router and serialiser
/// together, driven by `URLSession` the way the iOS client will drive it.
@Suite("HTTP listener", .serialized)
struct HTTPListenerTests {

    private static let key = TestLibrary.key

    /// Starts a loopback listener for the length of `body`.
    private func withListener<T>(
        limits: HTTPListener.Limits = .init(),
        _ body: (_ baseURL: URL) async throws -> T
    ) async throws -> T {
        let library = try await TestLibrary()
        let server = library.server(version: "0.0.0-test")
        let listener = try HTTPListener.loopback(limits: limits) { await server.respond(to: $0) }
        let port = try await listener.start()
        defer { listener.stop() }
        return try await body(try #require(URL(string: "http://127.0.0.1:\(port)")))
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    private func status(of data: Data) throws -> String? {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["subsonic-response"] as? [String: Any])?["status"] as? String
    }

    @Test("ping answers over a socket")
    func ping() async throws {
        try await withListener { base in
            var components = try #require(URLComponents(
                url: base.appendingPathComponent("rest/ping.view"), resolvingAgainstBaseURL: false))
            components.queryItems = [.init(name: "apiKey", value: Self.key),
                                     .init(name: "f", value: "json")]
            let (data, response) = try await session.data(from: try #require(components.url))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
            #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(try status(of: data) == "ok")
        }
    }

    @Test("A request without a key is refused over a socket")
    func unauthenticated() async throws {
        try await withListener { base in
            let (data, _) = try await session.data(from: base.appendingPathComponent("rest/ping"))
            #expect(try status(of: data) == "failed")
        }
    }

    @Test("Several requests in a row each get an answer")
    func sequential() async throws {
        try await withListener { base in
            let url = base.appendingPathComponent("rest/getOpenSubsonicExtensions")
            for _ in 0..<20 {
                let (data, _) = try await session.data(from: url)
                #expect(try status(of: data) == "ok")
            }
        }
    }

    @Test("HEAD gets headers and no body")
    func head() async throws {
        try await withListener { base in
            var request = URLRequest(url: base.appendingPathComponent("rest/getOpenSubsonicExtensions"))
            request.httpMethod = "HEAD"
            let (data, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(data.isEmpty)
        }
    }

    @Test("POST is refused with 405 before it reaches an endpoint")
    func post() async throws {
        try await withListener { base in
            var request = URLRequest(url: base.appendingPathComponent("rest/ping"))
            request.httpMethod = "POST"
            let (_, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 405)
        }
    }

    @Test("An oversized request head is refused with 431")
    func oversized() async throws {
        try await withListener { base in
            var request = URLRequest(url: base.appendingPathComponent("rest/ping"))
            request.setValue(String(repeating: "a", count: 20_000), forHTTPHeaderField: "X-Pad")
            let (_, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 431)
        }
    }

    @Test("A client that connects and sends nothing is timed out")
    func silentClient() async throws {
        var limits = HTTPListener.Limits()
        limits.headTimeout = 0.3
        try await withListener(limits: limits) { base in
            let port = try #require(base.port)
            let reply = try await rawExchange(port: port, send: Data())
            #expect(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 408 "))
        }
    }

    @Test("Garbage on the socket gets a 400, not a hang")
    func garbage() async throws {
        try await withListener { base in
            let port = try #require(base.port)
            let reply = try await rawExchange(
                port: port, send: Data("\u{1}\u{2}\u{3} not http at all\r\n\r\n".utf8))
            #expect(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 400 "))
        }
    }

    /// Writes `send` to the port and returns everything the server sends back
    /// before it closes the connection.
    private func rawExchange(port: Int, send: Data) async throws -> Data {
        let (input, output) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(InputStream, OutputStream), any Error>) in
            var input: InputStream?
            var output: OutputStream?
            Stream.getStreamsToHost(withName: "127.0.0.1", port: port,
                                    inputStream: &input, outputStream: &output)
            if let input, let output {
                continuation.resume(returning: (input, output))
            } else {
                continuation.resume(throwing: URLError(.cannotConnectToHost))
            }
        }
        return try await Task.detached {
            input.open()
            output.open()
            defer { input.close(); output.close() }
            if !send.isEmpty {
                _ = send.withUnsafeBytes {
                    output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: send.count)
                }
            }
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                received.append(buffer, count: count)
            }
            return received
        }.value
    }
}
