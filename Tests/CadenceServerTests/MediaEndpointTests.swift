import Testing
import Foundation
import CadenceCore
import CadenceLibrary
@testable import CadenceServer

@Suite("Byte ranges")
struct ByteRangeTests {

    @Test("The forms a player seeks with")
    func forms() {
        #expect(ByteRange.resolve("bytes=0-99", size: 1000) == .partial(offset: 0, length: 100))
        #expect(ByteRange.resolve("bytes=500-", size: 1000) == .partial(offset: 500, length: 500))
        #expect(ByteRange.resolve("bytes=-200", size: 1000) == .partial(offset: 800, length: 200))
        #expect(ByteRange.resolve("bytes=999-999", size: 1000) == .partial(offset: 999, length: 1))
        #expect(ByteRange.resolve("bytes=0-0", size: 1000) == .partial(offset: 0, length: 1))
    }

    @Test("A range reaching past the end is brought back inside the file")
    func clamped() {
        #expect(ByteRange.resolve("bytes=900-5000", size: 1000) == .partial(offset: 900, length: 100))
        #expect(ByteRange.resolve("bytes=-5000", size: 1000) == .partial(offset: 0, length: 1000))
        #expect(ByteRange.resolve("bytes=0-999999999999999999", size: 1000)
                == .partial(offset: 0, length: 1000))
    }

    @Test("A range that starts outside the file cannot be satisfied")
    func unsatisfiable() {
        #expect(ByteRange.resolve("bytes=1000-", size: 1000) == .unsatisfiable)
        #expect(ByteRange.resolve("bytes=1000-2000", size: 1000) == .unsatisfiable)
        #expect(ByteRange.resolve("bytes=-0", size: 1000) == .unsatisfiable)
        #expect(ByteRange.resolve("bytes=0-", size: 0) == .unsatisfiable)
        #expect(ByteRange.resolve("bytes=-1", size: 0) == .unsatisfiable)
    }

    @Test("Anything else is ignored, and the whole file is sent", arguments: [
        "bytes=", "bytes=-", "bytes=abc-def", "bytes=10-5", "bytes=0-99,200-299",
        "bytes= 0-99", "bytes=0 - 99", "bytes=+1-5", "bytes=-1-5", "bytes=1.5-9",
        "items=0-99", "0-99", "", "BYTES=0-99",
        "bytes=99999999999999999999-", "bytes=0-99999999999999999999",
        "bytes=0x10-0x20", "bytes=١-٢",
    ])
    func ignored(header: String) {
        #expect(ByteRange.resolve(header, size: 1000) == .whole)
    }

    @Test("No header means the whole file")
    func noHeader() {
        #expect(ByteRange.resolve(nil, size: 1000) == .whole)
    }

    /// Whatever the header says, the result lies inside the file.
    @Test("Random range headers never produce a range outside the file")
    func fuzz() {
        var generator = SeededGenerator(seed: 0xB17E_5A9E)
        let alphabet = Array("0123456789-=,bytes ")
        for _ in 0..<50_000 {
            let size = UInt64.random(in: 0...5000, using: &generator)
            let length = Int.random(in: 0...24, using: &generator)
            let tail = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            let header = Bool.random(using: &generator) ? "bytes=" + tail : tail
            if case .partial(let offset, let count) = ByteRange.resolve(header, size: size) {
                #expect(count > 0)
                #expect(offset < size)
                #expect(offset + count <= size)
            }
        }
    }
}

/// A library whose tracks are real files with known contents.
private struct MediaFixture {
    let server: TestServer
    let library: TestLibrary
    /// 300,000 bytes, so a full read spans several of the listener's chunks.
    let bytes: Data
    let songID: String
    let fileURL: URL

    init() async throws {
        library = try await TestLibrary()
        let music = library.directory.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        var generator = SeededGenerator(seed: 0xA0D1_0F11)
        bytes = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        fileURL = music.appendingPathComponent("01 Slow Hours.flac")
        try bytes.write(to: fileURL)

        let track = Track(url: fileURL, title: "Slow Hours", artist: "Vera Lindqvist",
                          albumTitle: "Sound of the Slow Hours", duration: 200)
        try await library.store.upsert([track])
        songID = "tr-" + track.id.uuidString.lowercased()
        server = library.server()
    }

    func header(_ response: HTTPResponse, _ name: String) -> String? {
        response.headers.first { $0.name == name }?.value
    }
}

@Suite("Streaming")
struct StreamingTests {

    @Test("stream answers with the whole file and says it takes ranges",
          arguments: ["stream", "download", "stream.view"])
    func whole(endpoint: String) async throws {
        let fixture = try await MediaFixture()
        let response = await fixture.server.get(endpoint, [("id", fixture.songID)])
        #expect(response.status == .ok)
        #expect(response.contentType == "audio/flac")
        #expect(fixture.header(response, "Accept-Ranges") == "bytes")
        #expect(response.file == FileBody(url: fixture.fileURL, offset: 0, length: 300_000))
        #expect(response.contentLength == 300_000)
    }

    @Test("A range answers 206 with exactly that part")
    func partial() async throws {
        let fixture = try await MediaFixture()
        let response = await fixture.server.get(
            "stream", [("id", fixture.songID)], headers: ["range": "bytes=1000-1999"])
        #expect(response.status == .partialContent)
        #expect(fixture.header(response, "Content-Range") == "bytes 1000-1999/300000")
        #expect(response.file == FileBody(url: fixture.fileURL, offset: 1000, length: 1000))
    }

    @Test("A range outside the file answers 416 and states the size")
    func unsatisfiable() async throws {
        let fixture = try await MediaFixture()
        let response = await fixture.server.get(
            "stream", [("id", fixture.songID)], headers: ["range": "bytes=300000-"])
        #expect(response.status == .rangeNotSatisfiable)
        #expect(fixture.header(response, "Content-Range") == "bytes */300000")
        #expect(response.file == nil)
        #expect(response.body.isEmpty)
    }

    @Test("The transcoding parameters change nothing")
    func transcodingIgnored() async throws {
        let fixture = try await MediaFixture()
        let response = await fixture.server.get("stream", [
            ("id", fixture.songID), ("maxBitRate", "64"), ("format", "mp3"),
            ("estimateContentLength", "true"),
        ])
        #expect(response.contentType == "audio/flac")
        #expect(response.contentLength == 300_000)
    }

    @Test("stream needs a key and an id")
    func refusals() async throws {
        let fixture = try await MediaFixture()
        let noKey = await fixture.server.get("stream", [("id", fixture.songID)],
                                             authenticated: false)
        #expect(noKey.errorCode == 44)
        #expect(noKey.file == nil)
        #expect(await fixture.server.get("stream").errorCode == 10)
    }

    @Test("Only a song id opens a file", arguments: [
        "../../etc/passwd", "/etc/passwd", "file:///etc/passwd", "music/01 Slow Hours.flac",
        "01 Slow Hours.flac", "tr-", "tr-../../etc/passwd", "tr-00000000-0000-0000-0000-000000000000",
        "al-00000000000000000000000000000000", "%2e%2e%2f", "..", ".", "~", "\u{0}",
    ])
    func hostileIDs(id: String) async throws {
        let fixture = try await MediaFixture()
        for endpoint in ["stream", "download"] {
            let response = await fixture.server.get(endpoint, [("id", id)])
            #expect(response.errorCode == 70, "\(endpoint) \(id)")
            #expect(response.file == nil)
        }
    }

    /// The fixture's real path, sent as an id, must not open the file either.
    @Test("The file's own path is not an id")
    func pathIsNotAnID() async throws {
        let fixture = try await MediaFixture()
        for id in [fixture.fileURL.path, fixture.fileURL.absoluteString] {
            let response = await fixture.server.get("stream", [("id", id)])
            #expect(response.errorCode == 70)
            #expect(response.file == nil)
        }
    }

    @Test("A track whose file has gone is not found, without saying where it was")
    func missingFile() async throws {
        let fixture = try await MediaFixture()
        try FileManager.default.removeItem(at: fixture.fileURL)
        let response = await fixture.server.get("stream", [("id", fixture.songID)])
        #expect(response.errorCode == 70)
        #expect(!response.text.contains("music"))
        #expect(!response.text.contains(fixture.library.directory.lastPathComponent))
    }

    @Test("A file swapped for a symbolic link is refused")
    func symlinkRefused() async throws {
        let fixture = try await MediaFixture()
        let secret = fixture.library.directory.appendingPathComponent("secret.txt")
        try Data("not music".utf8).write(to: secret)
        try FileManager.default.removeItem(at: fixture.fileURL)
        try FileManager.default.createSymbolicLink(at: fixture.fileURL, withDestinationURL: secret)

        let response = await fixture.server.get("stream", [("id", fixture.songID)])
        #expect(response.errorCode == 70)
        #expect(response.file == nil)
    }

    @Test("A file swapped for a directory is refused")
    func directoryRefused() async throws {
        let fixture = try await MediaFixture()
        try FileManager.default.removeItem(at: fixture.fileURL)
        try FileManager.default.createDirectory(at: fixture.fileURL,
                                                withIntermediateDirectories: false)
        #expect(await fixture.server.get("stream", [("id", fixture.songID)]).errorCode == 70)
    }
}

/// The same, over a socket: what a client actually receives.
@Suite("Streaming over a socket", .serialized)
struct StreamingSocketTests {

    private func withListener<T>(
        _ fixture: MediaFixture, _ body: (_ url: URL) async throws -> T
    ) async throws -> T {
        let server = fixture.server
        let listener = try HTTPListener.loopback { await server.respond(to: $0) }
        let port = try await listener.start()
        defer { listener.stop() }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/rest/stream"
        components.queryItems = [.init(name: "id", value: fixture.songID),
                                 .init(name: "apiKey", value: TestLibrary.key)]
        return try await body(try #require(components.url))
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    @Test("The whole file arrives, byte for byte")
    func whole() async throws {
        let fixture = try await MediaFixture()
        try await withListener(fixture) { url in
            let (data, response) = try await session.data(from: url)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type") == "audio/flac")
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "300000")
            #expect(data == fixture.bytes)
        }
    }

    @Test("Seeking: each range arrives as exactly those bytes", arguments: [
        (0, 99), (1000, 1999), (65_535, 65_537), (131_072, 262_143), (299_999, 299_999),
    ])
    func ranges(first: Int, last: Int) async throws {
        let fixture = try await MediaFixture()
        try await withListener(fixture) { url in
            var request = URLRequest(url: url)
            request.setValue("bytes=\(first)-\(last)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(http.value(forHTTPHeaderField: "Content-Range")
                    == "bytes \(first)-\(last)/300000")
            #expect(data == fixture.bytes.subdata(in: first..<(last + 1)))
        }
    }

    @Test("An open-ended range and a suffix range arrive correctly")
    func openEnded() async throws {
        let fixture = try await MediaFixture()
        try await withListener(fixture) { url in
            var request = URLRequest(url: url)
            request.setValue("bytes=250000-", forHTTPHeaderField: "Range")
            let tail = try await session.data(for: request).0
            #expect(tail == fixture.bytes.suffix(50_000))

            request.setValue("bytes=-70000", forHTTPHeaderField: "Range")
            let suffix = try await session.data(for: request).0
            #expect(suffix == fixture.bytes.suffix(70_000))
        }
    }

    @Test("HEAD reports the size and sends nothing")
    func head() async throws {
        let fixture = try await MediaFixture()
        try await withListener(fixture) { url in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let (data, response) = try await session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "300000")
            #expect(data.isEmpty)
        }
    }

    @Test("A range outside the file is 416 over the wire")
    func unsatisfiable() async throws {
        let fixture = try await MediaFixture()
        try await withListener(fixture) { url in
            var request = URLRequest(url: url)
            request.setValue("bytes=999999-", forHTTPHeaderField: "Range")
            let (_, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 416)
        }
    }

    /// The response is built from the file's size at request time. If the file
    /// is cut short before the listener opens it, the client must get an
    /// error, not a head promising bytes that never come.
    @Test("A file that shrinks after the response is built gets a 500, not a short body")
    func shrunkFile() async throws {
        let fixture = try await MediaFixture()
        let stale = await fixture.server.get("stream", [("id", fixture.songID)])
        try Data("tiny".utf8).write(to: fixture.fileURL)

        let listener = try HTTPListener.loopback { _ in stale }
        let port = try await listener.start()
        defer { listener.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/rest/stream"))
        let (_, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 500)
    }

    @Test("Several streams at once each arrive whole")
    func concurrent() async throws {
        let fixture = try await MediaFixture()
        try await withListener(fixture) { url in
            try await withThrowingTaskGroup(of: Data.self) { group in
                for _ in 0..<6 {
                    group.addTask { try await self.session.data(from: url).0 }
                }
                for try await data in group {
                    #expect(data == fixture.bytes)
                }
            }
        }
    }
}

@Suite("Cover art")
struct CoverArtTests {

    private static let png: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAHUlEQVQoz2P8//8/AzGAiYFIMKpwVOGowlGFowoBAAWBAwsGCPzsAAAAAElFTkSuQmCC") ?? Data()

    @Test("A cover comes back as the bytes that were stored, with their type")
    func full() async throws {
        let library = try await TestLibrary()
        let id = try await library.artwork.store(Self.png)
        let response = await library.server().get("getCoverArt", [("id", id)])
        #expect(response.status == .ok)
        #expect(response.contentType == "image/png")
        #expect(response.body == Self.png)
    }

    @Test("A sized cover is an image, and sizes are rounded to a fixed few")
    func sized() async throws {
        let library = try await TestLibrary()
        let id = try await library.artwork.store(Self.png)
        let server = library.server()
        for size in 1...300 {
            let response = await server.get("getCoverArt", [("id", id), ("size", "\(size)")])
            #expect(response.contentType == "image/png")
            #expect(!response.body.isEmpty)
        }
        // 300 different sizes asked for; four thumbnail files made: 64, 128,
        // 256, and 512 for the sizes from 257 up.
        let thumbnails = try FileManager.default.contentsOfDirectory(
            at: library.directory.appendingPathComponent("art/thumbnails"),
            includingPropertiesForKeys: nil)
        #expect(thumbnails.count == 4)

        let huge = await server.get("getCoverArt", [("id", id), ("size", "99999")])
        #expect(huge.contentType == "image/png")
    }

    @Test("A cover id is a content address or it is nothing", arguments: [
        "aa11", "../../library.sqlite", "../originals/x", "/etc/passwd", "",
        String(repeating: "g", count: 64), String(repeating: "A", count: 64),
        String(repeating: "a", count: 63), String(repeating: "a", count: 65),
        String(repeating: "a", count: 62) + "/.", String(repeating: "a", count: 63) + "\u{0}",
    ])
    func hostileIDs(id: String) async throws {
        let library = try await TestLibrary()
        _ = try await library.artwork.store(Self.png)
        let response = await library.server().get("getCoverArt", [("id", id)])
        #expect(response.errorCode == (id.isEmpty ? 10 : 70))
        #expect(response.contentType == "application/json; charset=utf-8")
    }

    @Test("A well-formed id with no cover behind it is not found")
    func unknown() async throws {
        let library = try await TestLibrary()
        let response = await library.server().get(
            "getCoverArt", [("id", String(repeating: "a", count: 64))])
        #expect(response.errorCode == 70)
    }

    @Test("Stored bytes that are not an image are not served")
    func notAnImage() async throws {
        let library = try await TestLibrary()
        let id = try await library.artwork.store(Data("<script>alert(1)</script>".utf8))
        #expect(await library.server().get("getCoverArt", [("id", id)]).errorCode == 70)
    }

    @Test("Cover art needs a key, and a size that is a number")
    func refusals() async throws {
        let library = try await TestLibrary()
        let id = try await library.artwork.store(Self.png)
        let server = library.server()
        #expect(await server.get("getCoverArt", [("id", id)], authenticated: false).errorCode == 44)
        #expect(await server.get("getCoverArt", [("id", id), ("size", "big")]).errorCode == 10)
    }

    @Test("Image types are read from the bytes")
    func sniffing() {
        #expect(MediaType.image(sniffing: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(MediaType.image(sniffing: Self.png) == "image/png")
        #expect(MediaType.image(sniffing: Data("GIF89a".utf8)) == "image/gif")
        #expect(MediaType.image(sniffing: Data("RIFF\u{1}\u{2}\u{3}\u{4}WEBPVP8 ".utf8)) == "image/webp")
        #expect(MediaType.image(sniffing: Data("<svg xmlns=".utf8)) == nil)
        #expect(MediaType.image(sniffing: Data()) == nil)
    }
}
