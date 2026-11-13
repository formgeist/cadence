import Foundation

/// One parsed request. Everything in it has already been through
/// `HTTPRequestParser`'s limits, so nothing downstream needs to ask how big
/// it might be.
public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case get = "GET"
        case head = "HEAD"
        /// Accepted by the parser for one route only, pairing. The router
        /// refuses it everywhere else, so no library endpoint can be reached
        /// with a method that carries a body.
        case post = "POST"
    }

    public var method: Method
    /// The path as sent, percent-decoded, without the query. It is only ever
    /// compared against a fixed set of route names. It is never joined to a
    /// directory or handed to the file system.
    public var path: String
    /// Query parameters in the order sent, percent-decoded.
    public var query: [(name: String, value: String)]
    /// Header names lowercased. A repeated header keeps its first value.
    public var headers: [String: String]
    /// Empty for `GET` and `HEAD`, which may not carry one.
    public var body: Data

    public init(method: Method, path: String,
                query: [(name: String, value: String)] = [],
                headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// The first value sent for `name`, or nil.
    public func parameter(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    public static func == (a: HTTPRequest, b: HTTPRequest) -> Bool {
        a.method == b.method && a.path == b.path && a.headers == b.headers
            && a.body == b.body
            && a.query.map(\.name) == b.query.map(\.name)
            && a.query.map(\.value) == b.query.map(\.value)
    }
}

/// Turns bytes off a socket into an `HTTPRequest`, or into the status to
/// refuse them with.
///
/// This is the first code that touches input from the network, on what may be
/// a hostile Wi-Fi network, so it is written to refuse rather than to cope:
///
/// - It accepts exactly what the server answers: `GET` and `HEAD` with no
///   body, and `POST` with a small one of declared length, which only the
///   pairing route takes. HTTP/1.0 and 1.1.
/// - Every size is bounded before anything is allocated for it.
/// - Anything it does not recognise is an error, not a guess. Lenient parsing
///   is where two parties come to disagree about what a request says.
///
/// It is a pure function of the bytes, with no I/O and no state, which is
/// what lets the fuzz tests run it millions of times.
public enum HTTPRequestParser {

    public struct Limits: Sendable {
        /// Request line and headers together, including the blank line.
        public var headBytes = 16 * 1024
        public var targetBytes = 8 * 1024
        public var headerCount = 64
        public var parameterCount = 64
        /// The most a `POST` may carry. A pairing request is a six-digit code
        /// and a device name.
        public var bodyBytes = 1024

        public init() {}
    }

    public enum Result: Sendable, Equatable {
        /// The head has not all arrived. Read more and try again.
        case incomplete
        case request(HTTPRequest)
        /// Refuse with this status and close.
        case failure(HTTPStatus)
    }

    public static func parse(_ data: Data, limits: Limits = Limits()) -> Result {
        let bytes = [UInt8](data.prefix(limits.headBytes))
        guard let headEnd = firstRange(of: [13, 10, 13, 10], in: bytes) else {
            // No blank line yet. If the limit is already spent, it never will
            // be one this server accepts.
            return data.count >= limits.headBytes ? .failure(.headerFieldsTooLarge) : .incomplete
        }

        let lines = split(bytes[..<headEnd])
        guard let requestLine = lines.first else { return .failure(.badRequest) }

        // METHOD SP target SP HTTP/1.x, single spaces, nothing else.
        let parts = requestLine.split(separator: 32, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .failure(.badRequest) }
        guard let version = ascii(parts[2]), version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .failure(.versionNotSupported)
        }
        guard let methodName = ascii(parts[0]) else { return .failure(.badRequest) }
        guard let method = HTTPRequest.Method(rawValue: methodName) else {
            return .failure(.methodNotAllowed)
        }
        guard parts[1].count <= limits.targetBytes else { return .failure(.uriTooLong) }
        guard let target = ascii(parts[1]), target.hasPrefix("/") else {
            return .failure(.badRequest)
        }

        var headers: [String: String] = [:]
        guard lines.count - 1 <= limits.headerCount else { return .failure(.headerFieldsTooLarge) }
        for line in lines.dropFirst() {
            // A line starting with whitespace is the obsolete header folding.
            guard let first = line.first, first != 32, first != 9,
                  let colon = line.firstIndex(of: 58) else { return .failure(.badRequest) }
            let nameBytes = line[..<colon]
            guard !nameBytes.isEmpty, nameBytes.allSatisfy(isTokenByte),
                  let name = ascii(nameBytes) else { return .failure(.badRequest) }
            let valueBytes = line[line.index(after: colon)...]
            // Control characters in a value are how a header is smuggled.
            guard valueBytes.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else {
                return .failure(.badRequest)
            }
            let value = String(decoding: valueBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            if headers[key] == nil { headers[key] = value }
        }

        // A body is only ever a declared number of bytes. Chunked encoding
        // is refused, so the only arithmetic here is one bounded length.
        if headers["transfer-encoding"] != nil { return .failure(.badRequest) }
        var bodyLength = 0
        if let length = headers["content-length"] {
            // Few digits, so the value cannot overflow before it is checked.
            guard !length.isEmpty, length.utf8.count <= 9,
                  length.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let value = Int(length) else { return .failure(.badRequest) }
            bodyLength = value
        } else if method == .post {
            return .failure(.lengthRequired)
        }
        guard bodyLength <= (method == .post ? limits.bodyBytes : 0) else {
            return .failure(.contentTooLarge)
        }
        let bodyStart = headEnd + 4
        // The head is complete but the body is still arriving.
        guard data.count >= bodyStart + bodyLength else { return .incomplete }
        // One request per connection: bytes after it are not a second
        // request, they are something trying to be one.
        guard data.count == bodyStart + bodyLength else { return .failure(.badRequest) }
        let body = Data(data.dropFirst(bodyStart).prefix(bodyLength))

        let (rawPath, rawQuery) = cut(target, at: "?")
        guard !rawPath.contains("#"), let path = percentDecode(rawPath, plusIsSpace: false) else {
            return .failure(.badRequest)
        }

        var query: [(name: String, value: String)] = []
        if let rawQuery, !rawQuery.isEmpty {
            let pairs = rawQuery.split(separator: "&", omittingEmptySubsequences: true)
            guard pairs.count <= limits.parameterCount else { return .failure(.uriTooLong) }
            for pair in pairs {
                let (rawName, rawValue) = cut(String(pair), at: "=")
                guard let name = percentDecode(rawName, plusIsSpace: true),
                      let value = percentDecode(rawValue ?? "", plusIsSpace: true),
                      !name.isEmpty else { return .failure(.badRequest) }
                query.append((name, value))
            }
        }

        return .request(HTTPRequest(method: method, path: path, query: query,
                                    headers: headers, body: body))
    }

    // MARK: - Pieces

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where haystack[start] == needle[0]
            && haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start
        }
        return nil
    }

    /// Splits on CRLF. A bare CR or LF is left inside its line, where the
    /// header value check refuses it.
    private static func split(_ bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == 13, index + 1 < bytes.endIndex, bytes[index + 1] == 10 {
                lines.append(bytes[start..<index])
                index += 2
                start = index
            } else {
                index += 1
            }
        }
        lines.append(bytes[start..<bytes.endIndex])
        return lines
    }

    /// Printable ASCII only: no spaces, no control characters, nothing above
    /// 126. The request line is made of nothing else.
    private static func ascii(_ bytes: ArraySlice<UInt8>) -> String? {
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 > 32 && $0 < 127 }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// RFC 9110 `tchar`.
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122: true
        case 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126: true
        default: false
        }
    }

    private static func cut(_ text: String, at separator: Character) -> (String, String?) {
        guard let index = text.firstIndex(of: separator) else { return (text, nil) }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    /// Strict: a `%` not followed by two hex digits, a decoded NUL, or bytes
    /// that are not UTF-8 all fail. `removingPercentEncoding` would accept
    /// the first and pass the second through.
    private static func percentDecode(_ text: String, plusIsSpace: Bool) -> String? {
        var decoded: [UInt8] = []
        decoded.reserveCapacity(text.utf8.count)
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            switch byte {
            case 37:
                guard let high = iterator.next().flatMap(hexValue),
                      let low = iterator.next().flatMap(hexValue) else { return nil }
                let value = high << 4 | low
                guard value != 0 else { return nil }
                decoded.append(value)
            case 43 where plusIsSpace:
                decoded.append(32)
            default:
                decoded.append(byte)
            }
        }
        return String(data: Data(decoded), encoding: .utf8)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
