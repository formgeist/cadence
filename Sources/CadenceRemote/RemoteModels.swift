import Foundation

/// The library as the server describes it, decoded from the OpenSubsonic
/// wire format.
///
/// Field names are the protocol's. These are not CadenceCore's types: they
/// say what the server sent, with optional fields left optional, and the app
/// maps them onto its own models.
///
/// Decoding is lenient where the protocol is: a field the server leaves out
/// because it does not know it is nil, and a field this client does not know
/// is ignored, so a newer server that adds fields still decodes.

public struct RemoteArtistIndex: Decodable, Sendable, Equatable {
    /// The heading the server sorted the artists under: a letter, or `#`.
    public var name: String
    public var artist: [RemoteArtist]
}

public struct RemoteArtist: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var albumCount: Int?
    public var coverArt: String?
    /// Present from `artist(id:)`, absent in lists.
    public var album: [RemoteAlbum]?
}

public struct RemoteAlbum: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var artist: String?
    public var artistId: String?
    public var coverArt: String?
    public var songCount: Int
    /// Whole seconds.
    public var duration: Int
    /// ISO 8601. When the album was added to the library.
    public var created: String?
    public var year: Int?
    public var genre: String?
    /// Present from `album(id:)`, absent in lists.
    public var song: [RemoteSong]?
}

public struct RemoteSong: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var album: String?
    public var albumId: String?
    public var artist: String?
    public var artistId: String?
    /// The album artist's name. Older servers leave it out.
    public var displayAlbumArtist: String?
    public var track: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var coverArt: String?
    /// Whole seconds.
    public var duration: Int?
    /// The file's extension, such as `flac`.
    public var suffix: String?
    public var contentType: String?
    /// kbps. Absent for lossless files.
    public var bitRate: Int?
    public var bitDepth: Int?
    public var samplingRate: Int?
    public var channelCount: Int?
    public var created: String?
    /// ISO 8601. Set only where the answer is about likes.
    public var starred: String?
}

public struct RemotePlaylist: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var songCount: Int
    /// Whole seconds.
    public var duration: Int
    public var created: String?
    public var changed: String?
    public var coverArt: String?
    /// Present from `playlist(id:)`, absent in the list. In playlist order.
    public var entry: [RemoteSong]?
}

public struct RemoteStarred: Decodable, Sendable, Equatable {
    public var artist: [RemoteArtist]
    public var album: [RemoteAlbum]
    public var song: [RemoteSong]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The protocol leaves an empty list out entirely.
        artist = try container.decodeIfPresent([RemoteArtist].self, forKey: .artist) ?? []
        album = try container.decodeIfPresent([RemoteAlbum].self, forKey: .album) ?? []
        song = try container.decodeIfPresent([RemoteSong].self, forKey: .song) ?? []
    }

    private enum CodingKeys: String, CodingKey { case artist, album, song }
}

public typealias RemoteSearchResult = RemoteStarred

/// Which albums `albums(_:)` lists, and in what order. The ones the server
/// answers; it has no ratings or play counts by album, so the protocol's
/// "recent", "frequent" and "highest" lists are not offered.
public enum RemoteAlbumOrder: Sendable, Equatable, Hashable {
    case alphabeticalByName
    case alphabeticalByArtist
    /// Most recently added first.
    case newest
    case random
    /// Albums from these years, oldest first; newest first when `from` is
    /// later than `to`.
    case byYear(from: Int, to: Int)
    case byGenre(String)

    var parameters: [URLQueryItem] {
        switch self {
        case .alphabeticalByName: [.init(name: "type", value: "alphabeticalByName")]
        case .alphabeticalByArtist: [.init(name: "type", value: "alphabeticalByArtist")]
        case .newest: [.init(name: "type", value: "newest")]
        case .random: [.init(name: "type", value: "random")]
        case .byYear(let from, let to):
            [.init(name: "type", value: "byYear"),
             .init(name: "fromYear", value: String(from)),
             .init(name: "toYear", value: String(to))]
        case .byGenre(let genre):
            [.init(name: "type", value: "byGenre"), .init(name: "genre", value: genre)]
        }
    }
}

// MARK: - Envelope

/// `{"subsonic-response": {...}}`: the parts every answer has.
struct Envelope: Decodable {
    struct Body: Decodable {
        var status: String
        var serverVersion: String?
        var cadenceProtocolVersion: Int?
        var error: Failure?
    }
    struct Failure: Decodable {
        var code: Int
        var message: String?
    }
    var body: Body

    private enum CodingKeys: String, CodingKey { case body = "subsonic-response" }
}

/// The envelope's payload under one key, decoded as `Value`.
struct Payload<Value: Decodable>: Decodable {
    var value: Value

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyKey.self)
        let body = try root.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("subsonic-response"))
        guard let key = decoder.userInfo[Self.keyInfo] as? String else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No key"))
        }
        value = try body.decode(Value.self, forKey: AnyKey(key))
    }

    static var keyInfo: CodingUserInfoKey { CodingUserInfoKey(rawValue: "payloadKey")! }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// Wrappers for answers whose list sits one level down.

struct ArtistsPayload: Decodable { var index: [RemoteArtistIndex]? }
struct AlbumListPayload: Decodable { var album: [RemoteAlbum]? }
struct PlaylistsPayload: Decodable { var playlist: [RemotePlaylist]? }

/// Permission to download one song without the API key, for a few hours.
public struct RemoteDownloadToken: Decodable, Sendable, Equatable {
    public var token: String
    /// ISO 8601.
    public var expires: String

    public var expiryDate: Date? { try? Date(expires, strategy: .iso8601) }
}
