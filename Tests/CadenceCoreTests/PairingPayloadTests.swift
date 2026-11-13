import Testing
import Foundation
import CadenceCore

private let fingerprint = String(repeating: "ab", count: 32)
private let token = "Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6"

private func payload(host: String = "studio-mac.local", name: String = "Studio Mac") -> PairingPayload {
    PairingPayload(host: host, port: 4533, fingerprint: fingerprint, token: token, name: name)
}

/// A pairing URL with one field replaced, removed (nil) or added.
private func url(_ changes: [String: String?] = [:], scheme: String = "cadence",
                 host: String = "pair") -> URL {
    var fields: [(String, String)] = [
        ("v", "1"), ("host", "studio-mac.local"), ("port", "4533"), ("fp", fingerprint),
        ("token", token), ("name", "Studio Mac"),
    ]
    for (key, value) in changes {
        fields.removeAll { $0.0 == key }
        if let value { fields.append((key, value)) }
    }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
    return components.url!
}

@Suite("Pairing payload")
struct PairingPayloadTests {

    @Test("What the Mac writes, the phone reads back")
    func roundTrip() throws {
        let original = payload()
        let written = try #require(original.url)
        #expect(written.scheme == "cadence")
        #expect(try PairingPayload(url: written) == original)
    }

    @Test("Names and hosts of every kind survive the trip", arguments: [
        ("studio-mac.local", "Studio Mac"),
        ("192.168.1.20", "Søren's Mac mini"),
        ("fe80::1c2d:3e4f:5a6b:7c8d", "音楽 & Cadence?=#"),
        ("MAC.local", ""),
    ])
    func variety(host: String, name: String) throws {
        let original = payload(host: host, name: name)
        #expect(try PairingPayload(url: try #require(original.url)) == original)
    }

    @Test("A code from a newer Cadence says so, apart from every other error")
    func newerVersion() {
        #expect(throws: PairingPayload.ParseError.unsupportedVersion(2)) {
            _ = try PairingPayload(url: url(["v": "2"]))
        }
        // Even one that carries fields this version has never heard of.
        #expect(throws: PairingPayload.ParseError.unsupportedVersion(7)) {
            _ = try PairingPayload(url: url(["v": "7", "extra": "x"]))
        }
    }

    @Test("Things that are not pairing codes are not read as one", arguments: [
        "https://example.com/pair?v=1", "cadence://spotify-callback?code=abc",
        "cadence://pair", "cadence://pair/extra?v=1", "cadence:pair?v=1",
        "cadence://user@pair?v=1", "cadence://pair:80?v=1", "http://pair?v=1",
        "WIFI:S:Network;T:WPA;P:password;;", "tel:+4512345678", "cadence://",
    ])
    func notPairingCodes(text: String) throws {
        let parsed = try #require(URL(string: text))
        #expect(throws: PairingPayload.ParseError.notAPairingCode) {
            _ = try PairingPayload(url: parsed)
        }
    }

    @Test("A missing field is refused", arguments: ["v", "host", "port", "fp", "token", "name"])
    func missing(field: String) {
        #expect(throws: PairingPayload.ParseError.self) {
            _ = try PairingPayload(url: url([field: nil]))
        }
    }

    @Test("An extra or repeated field is refused")
    func extraFields() {
        #expect(throws: PairingPayload.ParseError.malformed("fields")) {
            _ = try PairingPayload(url: url(["apiKey": "abc"]))
        }
        var components = URLComponents(url: url(), resolvingAgainstBaseURL: false)!
        components.queryItems?.append(URLQueryItem(name: "host", value: "evil.example"))
        #expect(throws: PairingPayload.ParseError.malformed("host")) {
            _ = try PairingPayload(url: components.url!)
        }
    }

    /// A host goes into a URL the phone then connects to. Each of these would
    /// make that URL mean something other than "this host".
    @Test("A host that is more than a host is refused", arguments: [
        "", "mac.local/evil", "mac.local?x=1", "mac.local#frag", "user@mac.local",
        "user:pass@mac.local", "mac.local evil", "mac.local\n", "mac.local%2Fevil",
        "[::1]", ".mac.local", "-mac.local", "mac.local\\evil", "mäc.local",
        String(repeating: "a", count: 254),
    ])
    func hostileHosts(host: String) {
        #expect(throws: PairingPayload.ParseError.malformed("host")) {
            _ = try PairingPayload(url: url(["host": host]))
        }
    }

    @Test("A port that is not a port is refused", arguments: [
        "", "0", "65536", "99999", "-1", "80a", " 80", "8.0", "0x50", "123456",
    ])
    func ports(port: String) {
        #expect(throws: PairingPayload.ParseError.malformed("port")) {
            _ = try PairingPayload(url: url(["port": port]))
        }
    }

    @Test("A fingerprint must be exactly a lowercase SHA-256", arguments: [
        "", "abc", String(repeating: "ab", count: 31), String(repeating: "ab", count: 33),
        String(repeating: "AB", count: 32), String(repeating: "zz", count: 32),
        String(repeating: "ab", count: 31) + "a ",
    ])
    func fingerprints(value: String) {
        #expect(throws: PairingPayload.ParseError.malformed("fp")) {
            _ = try PairingPayload(url: url(["fp": value]))
        }
    }

    @Test("A token must be base64url text of a sensible length", arguments: [
        "", "short", String(repeating: "a", count: 15), String(repeating: "a", count: 129),
        "has space in the token here", "has+plus/and=padding==aaaaaaaa", "tökenwithnonascii12345",
    ])
    func tokens(value: String) {
        #expect(throws: PairingPayload.ParseError.malformed("token")) {
            _ = try PairingPayload(url: url(["token": value]))
        }
    }

    @Test("A name with control characters, or too long, is refused")
    func names() {
        for name in ["Mac\nmini", "Mac\u{0}", "Mac\u{1B}[31m", String(repeating: "a", count: 65)] {
            #expect(throws: PairingPayload.ParseError.malformed("name")) {
                _ = try PairingPayload(url: url(["name": name]))
            }
        }
    }

    @Test("Version must be a plain small number", arguments: ["", "one", "1.0", "-1", "01x", "99999"])
    func versions(value: String) {
        #expect(throws: PairingPayload.ParseError.malformed("v")) {
            _ = try PairingPayload(url: url(["v": value]))
        }
    }

    /// Whatever a camera reads, parsing returns a payload or throws. It never
    /// traps, and what it accepts always holds the invariants.
    @Test("Mutated codes never crash the parser")
    func fuzz() throws {
        let seed = Array(try #require(payload().url).absoluteString.utf8)
        let interesting: [UInt8] = [0, 10, 32, 35, 37, 38, 47, 58, 61, 63, 64, 91, 93, 255]
        var state: UInt64 = 0x51CA_DE0F_1234_5678
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        for _ in 0..<30_000 {
            var bytes = seed
            for _ in 0..<(1 + next() % 4) {
                let index = next() % bytes.count
                switch next() % 3 {
                case 0: bytes[index] = interesting[next() % interesting.count]
                case 1: bytes.remove(at: index)
                default: bytes.insert(interesting[next() % interesting.count], at: index)
                }
                if bytes.isEmpty { break }
            }
            guard let text = String(bytes: bytes, encoding: .utf8), let url = URL(string: text),
                  let parsed = try? PairingPayload(url: url) else { continue }
            #expect(parsed.fingerprint.count == 64)
            #expect(parsed.port > 0)
            #expect(!parsed.host.contains("/") && !parsed.host.contains("@"))
        }
    }
}
