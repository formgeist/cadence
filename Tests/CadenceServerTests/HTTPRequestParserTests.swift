import Testing
import Foundation
import CadenceServer

private func parse(_ text: String, limits: HTTPRequestParser.Limits = .init()) -> HTTPRequestParser.Result {
    HTTPRequestParser.parse(Data(text.utf8), limits: limits)
}

private func request(_ text: String) -> HTTPRequest? {
    if case .request(let request) = parse(text) { return request }
    return nil
}

@Suite("HTTP request parser")
struct HTTPRequestParserTests {

    // MARK: What it accepts

    @Test("A plain GET parses into method, path, query and headers")
    func plainGet() throws {
        let parsed = try #require(request(
            "GET /rest/ping.view?apiKey=abc&f=json HTTP/1.1\r\nHost: mac.local\r\nUser-Agent: Cadence/1\r\n\r\n"))
        #expect(parsed.method == .get)
        #expect(parsed.path == "/rest/ping.view")
        #expect(parsed.parameter("apiKey") == "abc")
        #expect(parsed.parameter("f") == "json")
        #expect(parsed.parameter("missing") == nil)
        #expect(parsed.headers["host"] == "mac.local")
        #expect(parsed.headers["user-agent"] == "Cadence/1")
    }

    @Test("HEAD and HTTP/1.0 are accepted")
    func headAndOldVersion() throws {
        #expect(request("HEAD /rest/ping HTTP/1.0\r\n\r\n")?.method == .head)
    }

    @Test("Query values are percent-decoded, and a plus is a space")
    func decoding() throws {
        let parsed = try #require(request(
            "GET /rest/search3?query=Sigur%20R%C3%B3s+live&empty= HTTP/1.1\r\n\r\n"))
        #expect(parsed.parameter("query") == "Sigur Rós live")
        #expect(parsed.parameter("empty") == "")
    }

    @Test("A repeated parameter keeps its first value")
    func repeatedParameter() throws {
        let parsed = try #require(request("GET /rest/ping?id=one&id=two HTTP/1.1\r\n\r\n"))
        #expect(parsed.parameter("id") == "one")
        #expect(parsed.query.count == 2)
    }

    @Test("A request that has not all arrived is incomplete, not wrong")
    func incomplete() {
        #expect(parse("") == .incomplete)
        #expect(parse("GET /rest/ping HTTP/1.1\r\nHost: mac") == .incomplete)
        #expect(parse("GET /rest/ping HTTP/1.1\r\nHost: mac.local\r\n") == .incomplete)
    }

    @Test("A Content-Length of zero is not a body")
    func zeroLength() {
        #expect(request("GET /rest/ping HTTP/1.1\r\nContent-Length: 0\r\n\r\n") != nil)
    }

    // MARK: What it refuses

    @Test("Any method that could change something is refused",
          arguments: ["PUT", "DELETE", "PATCH", "OPTIONS", "CONNECT", "TRACE", "get", "post"])
    func otherMethods(method: String) {
        #expect(parse("\(method) /rest/ping HTTP/1.1\r\n\r\n") == .failure(.methodNotAllowed))
    }

    @Test("A request body is refused, by length or by encoding")
    func bodies() {
        #expect(parse("GET /rest/ping HTTP/1.1\r\nContent-Length: 12\r\n\r\nhello world!")
                == .failure(.contentTooLarge))
        #expect(parse("GET /rest/ping HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
                == .failure(.badRequest))
        #expect(parse("GET /rest/ping HTTP/1.1\r\nContent-Length: -1\r\n\r\n")
                == .failure(.badRequest))
        #expect(parse("GET /rest/ping HTTP/1.1\r\nContent-Length: 1e3\r\n\r\n")
                == .failure(.badRequest))
    }

    @Test("Other HTTP versions are refused")
    func versions() {
        #expect(parse("GET /rest/ping HTTP/2.0\r\n\r\n") == .failure(.versionNotSupported))
        #expect(parse("GET /rest/ping HTTP/0.9\r\n\r\n") == .failure(.versionNotSupported))
        #expect(parse("GET /rest/ping\r\n\r\n") == .failure(.badRequest))
    }

    @Test("A malformed request line is refused", arguments: [
        "GET  /rest/ping HTTP/1.1\r\n\r\n",          // two spaces
        "GET rest/ping HTTP/1.1\r\n\r\n",            // no leading slash
        "GET http://mac.local/rest/ping HTTP/1.1\r\n\r\n",
        "GET /rest/ping HTTP/1.1 extra\r\n\r\n",
        "GET /rest/pi\tng HTTP/1.1\r\n\r\n",
        "GET /rest/ping#fragment HTTP/1.1\r\n\r\n",
        "\r\n\r\n",
    ])
    func requestLines(text: String) {
        #expect(parse(text) == .failure(.badRequest))
    }

    @Test("Broken percent-encoding is refused, not passed through", arguments: [
        "/rest/ping?id=%",
        "/rest/ping?id=%2",
        "/rest/ping?id=%zz",
        "/rest/ping?id=%00",          // NUL
        "/rest/ping?id=%ff%fe",       // not UTF-8
        "/rest/%00ping",
        "/rest/ping?=value",          // no name
    ])
    func percentEncoding(target: String) {
        #expect(parse("GET \(target) HTTP/1.1\r\n\r\n") == .failure(.badRequest))
    }

    @Test("Malformed headers are refused", arguments: [
        "Host mac.local",              // no colon
        ": value",                     // no name
        "Bad Name: value",             // space in name
        " folded: value",              // obsolete folding
        "Host: mac\u{0}.local",        // control character in value
        "X-Test: one\rX-Injected: two",// bare CR
        "X-Test: one\nX-Injected: two",// bare LF
    ])
    func headers(line: String) {
        #expect(parse("GET /rest/ping HTTP/1.1\r\n\(line)\r\n\r\n") == .failure(.badRequest))
    }

    // MARK: POST

    @Test("A POST with a declared body parses once the whole body has arrived")
    func post() throws {
        let head = "POST /pair HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n"
        #expect(parse(head) == .incomplete)
        #expect(parse(head + "{\"code\":") == .incomplete)
        let parsed = try #require(request(head + "{\"code\":\"1\"}"))
        #expect(parsed.method == .post)
        #expect(parsed.path == "/pair")
        #expect(parsed.body == Data("{\"code\":\"1\"}".utf8))
    }

    @Test("A POST must say how long its body is, and keep it small")
    func postLimits() {
        #expect(parse("POST /pair HTTP/1.1\r\n\r\n") == .failure(.lengthRequired))
        #expect(parse("POST /pair HTTP/1.1\r\nContent-Length: 1025\r\n\r\n")
                == .failure(.contentTooLarge))
        #expect(parse("POST /pair HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n")
                == .failure(.badRequest))
        #expect(parse("POST /pair HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
                == .failure(.badRequest))
        // The size is refused from the header, before any of the body is read.
        #expect(parse("POST /pair HTTP/1.1\r\nContent-Length: 5000\r\n\r\nab")
                == .failure(.contentTooLarge))
    }

    @Test("Bytes after the declared body are not a second request")
    func trailingBytes() {
        #expect(parse("POST /pair HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}GET /rest/ping HTTP/1.1\r\n\r\n")
                == .failure(.badRequest))
        #expect(parse("GET /rest/ping HTTP/1.1\r\n\r\nGET /rest/ping HTTP/1.1\r\n\r\n")
                == .failure(.badRequest))
    }

    @Test("A body of any bytes is carried as it is")
    func binaryBody() throws {
        var data = Data("POST /pair HTTP/1.1\r\nContent-Length: 4\r\n\r\n".utf8)
        data.append(contentsOf: [0x00, 0xFF, 0x0D, 0x0A])
        guard case .request(let parsed) = HTTPRequestParser.parse(data) else {
            Issue.record("did not parse")
            return
        }
        #expect(parsed.body == Data([0x00, 0xFF, 0x0D, 0x0A]))
    }

    // MARK: Limits

    @Test("A head that outgrows the limit is refused without waiting for its end")
    func headTooLarge() {
        let flood = "GET /rest/ping HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 20_000)
        #expect(parse(flood) == .failure(.headerFieldsTooLarge))
    }

    @Test("Too long a target, too many headers and too many parameters are refused")
    func counts() {
        var limits = HTTPRequestParser.Limits()
        limits.targetBytes = 32
        #expect(parse("GET /rest/ping?query=\(String(repeating: "a", count: 40)) HTTP/1.1\r\n\r\n",
                      limits: limits) == .failure(.uriTooLong))

        limits = HTTPRequestParser.Limits()
        limits.headerCount = 2
        #expect(parse("GET /rest/ping HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n", limits: limits)
                == .failure(.headerFieldsTooLarge))

        limits = HTTPRequestParser.Limits()
        limits.parameterCount = 2
        #expect(parse("GET /rest/ping?a=1&b=2&c=3 HTTP/1.1\r\n\r\n", limits: limits)
                == .failure(.uriTooLong))
    }

    // MARK: Paths

    /// The parser decodes a path and does nothing else with it. These are here
    /// to pin that: a traversal attempt is just a string that matches no route.
    @Test("A traversal attempt parses as an ordinary path that names no route")
    func traversal() throws {
        let parsed = try #require(request("GET /rest/..%2F..%2Fetc%2Fpasswd HTTP/1.1\r\n\r\n"))
        #expect(parsed.path == "/rest/../../etc/passwd")
    }

    // MARK: Fuzz

    /// Whatever arrives, the parser returns one of its three answers. It must
    /// not trap, hang or read past what it was given.
    @Test("Random bytes never crash the parser")
    func fuzzRandom() {
        var generator = SeededGenerator(seed: 0xCADE_0CE5)
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...600, using: &generator)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = HTTPRequestParser.parse(Data(bytes))
        }
    }

    @Test("Mutated POST requests never crash the parser or exceed the body limit")
    func fuzzPost() {
        let seedRequest = Array(
            "POST /pair HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 31\r\n\r\n{\"code\":\"123456\",\"name\":\"iPad\"}".utf8)
        let interesting: [UInt8] = [0, 10, 13, 32, 48, 49, 57, 58, 45, 43, 255]
        var generator = SeededGenerator(seed: 0x9A12_0057)
        for _ in 0..<40_000 {
            var bytes = seedRequest
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: bytes[index] = interesting.randomElement(using: &generator)!
                case 1: bytes.remove(at: index)
                default: bytes.insert(interesting.randomElement(using: &generator)!, at: index)
                }
                if bytes.isEmpty { break }
            }
            if case .request(let request) = HTTPRequestParser.parse(Data(bytes)) {
                #expect(request.body.count <= HTTPRequestParser.Limits().bodyBytes)
                #expect(request.method == .post || request.body.isEmpty)
            }
        }
    }

    /// Random bytes almost never get past the request line. Mutating a valid
    /// request reaches the header and query code that random input cannot.
    @Test("Mutated valid requests never crash the parser")
    func fuzzMutations() {
        let seedRequest = Array(
            "GET /rest/search3.view?apiKey=abc%20def&query=a+b&f=json HTTP/1.1\r\nHost: mac.local\r\nContent-Length: 0\r\nAccept: */*\r\n\r\n".utf8)
        let interesting: [UInt8] = [0, 9, 10, 13, 32, 37, 38, 43, 47, 58, 61, 63, 127, 255]
        var generator = SeededGenerator(seed: 0x5EED_F00D)
        for _ in 0..<40_000 {
            var bytes = seedRequest
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                switch Int.random(in: 0..<4, using: &generator) {
                case 0: bytes[index] = interesting.randomElement(using: &generator)!
                case 1: bytes.remove(at: index)
                case 2: bytes.insert(interesting.randomElement(using: &generator)!, at: index)
                default: bytes[index] = UInt8.random(in: 0...255, using: &generator)
                }
                if bytes.isEmpty { break }
            }
            let result = HTTPRequestParser.parse(Data(bytes))
            // Whatever survives mutation must still be within the limits.
            if case .request(let request) = result {
                #expect(request.body.count <= HTTPRequestParser.Limits().bodyBytes)
                #expect(request.method == .post || request.body.isEmpty)
            }
            if case .request(let request) = result {
                #expect(request.path.hasPrefix("/"))
                #expect(!request.path.utf8.contains(0))
                #expect(request.query.allSatisfy { !$0.value.utf8.contains(0) })
            }
        }
    }
}

/// SplitMix64. Seeded, so a fuzz failure reproduces.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
