import Foundation

public struct HTTPStatus: Sendable, Equatable {
    public var code: Int
    public var reason: String

    public init(_ code: Int, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    public static let ok = HTTPStatus(200, "OK")
    public static let partialContent = HTTPStatus(206, "Partial Content")
    public static let badRequest = HTTPStatus(400, "Bad Request")
    public static let notFound = HTTPStatus(404, "Not Found")
    public static let methodNotAllowed = HTTPStatus(405, "Method Not Allowed")
    public static let requestTimeout = HTTPStatus(408, "Request Timeout")
    public static let contentTooLarge = HTTPStatus(413, "Content Too Large")
    public static let uriTooLong = HTTPStatus(414, "URI Too Long")
    public static let rangeNotSatisfiable = HTTPStatus(416, "Range Not Satisfiable")
    public static let headerFieldsTooLarge = HTTPStatus(431, "Request Header Fields Too Large")
    public static let internalServerError = HTTPStatus(500, "Internal Server Error")
    public static let serviceUnavailable = HTTPStatus(503, "Service Unavailable")
    public static let versionNotSupported = HTTPStatus(505, "HTTP Version Not Supported")
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: HTTPStatus
    public var contentType: String?
    /// Headers beyond the ones `serialized` always writes.
    public var headers: [(name: String, value: String)]
    public var body: Data
    /// When set, the body is this part of a file and `body` is ignored. The
    /// listener sends it in pieces.
    public var file: FileBody?

    public init(status: HTTPStatus, contentType: String? = nil,
                headers: [(name: String, value: String)] = [], body: Data = Data(),
                file: FileBody? = nil) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
        self.file = file
    }

    /// The number of body bytes this response promises.
    public var contentLength: UInt64 { file?.length ?? UInt64(body.count) }

    /// A refusal with no body. The status line says all a client is owed;
    /// anything more risks describing the server to someone probing it.
    public static func empty(_ status: HTTPStatus) -> HTTPResponse {
        HTTPResponse(status: status)
    }

    /// The bytes to put on the wire. `includingBody` is false for `HEAD`,
    /// which gets the same headers, `Content-Length` included, and no body.
    ///
    /// Every response closes the connection. One request per connection keeps
    /// the connection handler free of pipelining and of any question about
    /// where one request ends and the next begins.
    public func serialized(includingBody: Bool = true) -> Data {
        var data = serializedHead()
        // A file body is not in memory; the listener sends it after the head.
        if includingBody, file == nil { data.append(body) }
        return data
    }

    /// The status line and headers, ending in the blank line.
    public func serializedHead() -> Data {
        var head = "HTTP/1.1 \(status.code) \(status.reason)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(contentLength)\r\n"
        head += "Connection: close\r\n"
        // A library's contents are private to its paired devices: nothing in
        // between should keep a copy, and nothing should guess a type.
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        for header in headers { head += "\(header.name): \(header.value)\r\n" }
        head += "\r\n"
        return Data(head.utf8)
    }

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.contentType == b.contentType && a.body == b.body
            && a.file == b.file
            && a.headers.map(\.name) == b.headers.map(\.name)
            && a.headers.map(\.value) == b.headers.map(\.value)
    }
}
