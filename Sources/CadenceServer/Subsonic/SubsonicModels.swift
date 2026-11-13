import Foundation
import CadenceCore
import CadenceLibrary

/// The Cadence library, as the OpenSubsonic API describes one.
///
/// Field names are the protocol's, not ours. An optional field that is nil is
/// left out of the JSON, which is how the protocol spells "unknown".
///
/// **No field carries a file path.** The protocol's `path` is optional and
/// omitted. A song says what kind of file it is (`suffix`, `contentType`) and
/// nothing about where it lives.

// MARK: - Ids

/// The ids that go on the wire. Each kind has a prefix, so an id handed to
/// the wrong endpoint fails to parse instead of finding something else.
enum WireID {
    static func song(_ id: Track.ID) -> String { "tr-" + id.uuidString.lowercased() }

    /// The track a song id names, or nil for anything that is not one. The
    /// id is parsed into a UUID before it goes near the store, so only a
    /// well-formed id ever becomes a query argument.
    static func track(from wire: String) -> Track.ID? {
        guard wire.hasPrefix("tr-") else { return nil }
        let body = String(wire.dropFirst(3))
        // `UUID(uuidString:)` accepts either case; ids are issued lowercase,
        // and only an id exactly as issued is accepted back.
        guard body == body.lowercased() else { return nil }
        return UUID(uuidString: body)
    }
}

// MARK: - Models

struct MusicFolders: Encodable, Sendable {
    struct Folder: Encodable, Sendable {
        var id: Int
        var name: String
    }
    var musicFolder: [Folder]
}

struct ArtistIndexes: Encodable, Sendable {
    struct Index: Encodable, Sendable {
        var name: String
        var artist: [ArtistItem]
    }
    var ignoredArticles: String
    var index: [Index]
}

struct ArtistItem: Encodable, Sendable {
    var id: String
    var name: String
    var albumCount: Int
    var coverArt: String?
    /// Present on `getArtist`, absent in lists.
    var album: [AlbumItem]?

    init(_ artist: Artist, coverArt: Artwork.ID?, albums: [AlbumItem]? = nil) {
        id = artist.stableID
        name = artist.name
        albumCount = artist.albumCount
        self.coverArt = coverArt
        album = albums
    }
}

struct AlbumItem: Encodable, Sendable {
    var id: String
    var name: String
    var artist: String
    var artistId: String
    var coverArt: String?
    var songCount: Int
    /// Whole seconds.
    var duration: Int
    var created: String
    var year: Int?
    var genre: String?
    /// Present on `getAlbum`, absent in lists.
    var song: [SongItem]?

    init(_ summary: SQLiteLibraryStore.AlbumSummary) {
        id = summary.key.stableID
        name = summary.key.title
        artist = summary.key.albumArtist
        artistId = StableID.artist(named: summary.key.albumArtist)
        coverArt = summary.artworkID
        songCount = summary.trackCount
        duration = Int(summary.duration.rounded())
        created = Timestamp.string(summary.dateAdded)
        year = summary.key.year
        genre = summary.genres.first
    }

    init(_ album: Album) {
        id = album.stableID
        name = album.title
        artist = album.albumArtist
        artistId = StableID.artist(named: album.albumArtist)
        coverArt = album.artworkID
        songCount = album.trackCount
        duration = Int(album.duration.rounded())
        created = Timestamp.string(album.dateAdded)
        year = album.year
        genre = album.tracks.compactMap(\.genre).sorted().first
        song = album.discs.flatMap(\.tracks).map(SongItem.init)
    }
}

struct SongItem: Encodable, Sendable {
    var id: String
    /// The album, which is a song's parent in the protocol's folder model.
    var parent: String
    var isDir = false
    var isVideo = false
    var type = "music"
    var title: String
    var album: String
    var albumId: String
    var artist: String
    /// The album artist's id: artists are listed by album artist, so that is
    /// the artist a client can open.
    var artistId: String
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var coverArt: String?
    var duration: Int
    var suffix: String
    var contentType: String
    /// kbps. Left out for lossless files, where the library does not record one.
    var bitRate: Int?
    var bitDepth: Int?
    var samplingRate: Int
    var channelCount: Int
    var created: String

    init(_ track: Track) {
        id = WireID.song(track.id)
        parent = track.albumKey.stableID
        title = track.title
        album = track.albumTitle
        albumId = track.albumKey.stableID
        artist = track.artist
        artistId = StableID.artist(named: track.albumArtist)
        self.track = track.trackNumber
        discNumber = track.discNumber
        year = track.year
        genre = track.genre
        coverArt = track.artworkID
        duration = Int(track.duration.rounded())
        // The extension is all a client learns of the file's name.
        suffix = track.url.pathExtension.lowercased()
        contentType = MediaType.audio(forExtension: suffix)
        bitRate = track.format.bitRate
        bitDepth = track.format.bitDepth
        samplingRate = Int(track.format.sampleRate)
        channelCount = track.format.channelCount
        created = Timestamp.string(track.dateAdded)
    }
}

struct AlbumList: Encodable, Sendable {
    var album: [AlbumItem]
}

struct SearchResult: Encodable, Sendable {
    var artist: [ArtistItem]
    var album: [AlbumItem]
    var song: [SongItem]
}

// MARK: - Formats

enum Timestamp {
    /// ISO 8601 in UTC, as the protocol's `created` fields are.
    static func string(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

enum MediaType {
    static func audio(forExtension suffix: String) -> String {
        switch suffix {
        case "flac": "audio/flac"
        case "mp3": "audio/mpeg"
        case "m4a", "m4b", "mp4", "alac": "audio/mp4"
        case "aac": "audio/aac"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "ogg", "oga": "audio/ogg"
        case "opus": "audio/opus"
        case "wv": "audio/x-wavpack"
        case "ape": "audio/x-ape"
        default: "application/octet-stream"
        }
    }
}
