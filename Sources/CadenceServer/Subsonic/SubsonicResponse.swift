import Foundation

/// The OpenSubsonic response envelope.
///
/// Every answer from `/rest/…`, success or failure, is one JSON object under
/// the key `subsonic-response`. A failure is still HTTP 200: the protocol
/// carries its errors inside the envelope, and clients read them from there.
///
/// Only JSON is produced. The protocol's default is XML, but the only
/// supported clients are Cadence's own, which ask for JSON, and a second
/// serialiser would be a second thing to keep correct.
public struct SubsonicResponse: Sendable {

    /// The Subsonic API version this server's responses follow.
    public static let apiVersion = "1.16.1"
    /// Cadence's own protocol number, raised when a change would break a
    /// paired client. A client compares it at connect time so that mismatched
    /// app and server releases fail with a clear message, not a decode error.
    public static let cadenceProtocolVersion = 1

    /// Error codes from the Subsonic API and its OpenSubsonic extensions.
    public enum ErrorCode: Int, Sendable {
        case generic = 0
        case missingParameter = 10
        /// The client used a way of signing in that this server does not
        /// offer, such as a user name and password.
        case authenticationMechanismNotSupported = 42
        case conflictingAuthentication = 43
        case invalidAPIKey = 44
        case notAuthorized = 50
        case notFound = 70
    }

    public struct Failure: Sendable, Equatable {
        public var code: ErrorCode
        public var message: String

        public init(_ code: ErrorCode, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    private enum Content: Sendable {
        case empty
        case payload(key: String, value: any Encodable & Sendable)
        case failure(Failure)
    }

    private let content: Content
    public var serverVersion: String

    /// A success with nothing but the envelope, as `ping` returns.
    public static func ok(serverVersion: String) -> SubsonicResponse {
        SubsonicResponse(content: .empty, serverVersion: serverVersion)
    }

    /// A success carrying one value under `key`, as every other endpoint does.
    public static func ok(
        _ key: String, _ value: some Encodable & Sendable, serverVersion: String
    ) -> SubsonicResponse {
        SubsonicResponse(content: .payload(key: key, value: value), serverVersion: serverVersion)
    }

    public static func failed(_ failure: Failure, serverVersion: String) -> SubsonicResponse {
        SubsonicResponse(content: .failure(failure), serverVersion: serverVersion)
    }

    public var failure: Failure? {
        if case .failure(let failure) = content { return failure }
        return nil
    }

    /// Sorted keys, so the same answer is the same bytes every time.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding fixed-shape values of our own types does not fail. If it
        // ever does, the client still gets a well-formed envelope.
        return (try? encoder.encode(Wrapper(response: self)))
            ?? Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"Internal error."}}}"#.utf8)
    }

    public func httpResponse(status: HTTPStatus = .ok) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json; charset=utf-8",
                     body: encoded())
    }

    // MARK: - Encoding

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Wrapper: Encodable {
        let response: SubsonicResponse

        func encode(to encoder: any Encoder) throws {
            var root = encoder.container(keyedBy: Key.self)
            var body = root.nestedContainer(keyedBy: Key.self, forKey: Key("subsonic-response"))
            try body.encode(SubsonicResponse.apiVersion, forKey: Key("version"))
            try body.encode("cadence", forKey: Key("type"))
            try body.encode(response.serverVersion, forKey: Key("serverVersion"))
            try body.encode(true, forKey: Key("openSubsonic"))
            try body.encode(SubsonicResponse.cadenceProtocolVersion,
                            forKey: Key("cadenceProtocolVersion"))

            switch response.content {
            case .empty:
                try body.encode("ok", forKey: Key("status"))
            case .payload(let key, let value):
                try body.encode("ok", forKey: Key("status"))
                try body.encode(value, forKey: Key(key))
            case .failure(let failure):
                try body.encode("failed", forKey: Key("status"))
                var error = body.nestedContainer(keyedBy: Key.self, forKey: Key("error"))
                try error.encode(failure.code.rawValue, forKey: Key("code"))
                try error.encode(failure.message, forKey: Key("message"))
            }
        }
    }
}
