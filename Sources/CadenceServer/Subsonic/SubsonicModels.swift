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
    static func playlist(_ id: Playlist.ID) -> String { "pl-" + id.uuidString.lowercased() }

    static func playlist(from wire: String) -> Playlist.ID? {
        uuid(from: wire, prefix: "pl-")
    }

    static func catalog(_ id: Catalog.ID) -> String { "ca-" + id.uuidString.lowercased() }

    static func catalog(from wire: String) -> Catalog.ID? {
        uuid(from: wire, prefix: "ca-")
    }

    /// The track a song id names, or nil for anything that is not one. The
    /// id is parsed into a UUID before it goes near the store, so only a
    /// well-formed id ever becomes a query argument.
    static func track(from wire: String) -> Track.ID? {
        uuid(from: wire, prefix: "tr-")
    }

    private static func uuid(from wire: String, prefix: String) -> UUID? {
        guard wire.hasPrefix(prefix) else { return nil }
        let body = String(wire.dropFirst(prefix.count))
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

    /// With its songs, as `getAlbum` answers; without, as a list entry.
    init(_ album: Album, includingSongs: Bool = true) {
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
        song = includingSongs ? album.discs.flatMap(\.tracks).map { SongItem($0) } : nil
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
    /// The album artist's name, an OpenSubsonic field. Without it a client
    /// listing songs on their own, as the Mac client does to build its
    /// library, would file each compilation track under its performer.
    var displayAlbumArtist: String
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
    /// When the song was liked. Set only where the answer is about likes.
    var starred: String?

    init(_ track: Track, starred: Date? = nil) {
        self.starred = starred.map(Timestamp.string)
        id = WireID.song(track.id)
        parent = track.albumKey.stableID
        title = track.title
        album = track.albumTitle
        albumId = track.albumKey.stableID
        artist = track.artist
        artistId = StableID.artist(named: track.albumArtist)
        displayAlbumArtist = track.albumArtist
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

struct Playlists: Encodable, Sendable {
    var playlist: [PlaylistItem]
}

struct PlaylistItem: Encodable, Sendable {
    var id: String
    var name: String
    var songCount: Int
    var duration: Int
    /// The Mac records when a playlist last changed, not when it was made, so
    /// both of the protocol's dates carry that. Left out for a playlist older
    /// than the record.
    var created: String?
    var changed: String?
    var coverArt: String?
    /// Present on `getPlaylist`, absent in the list.
    var entry: [SongItem]?

    init(_ playlist: Playlist, songs: [Track]? = nil) {
        id = WireID.playlist(playlist.id)
        name = playlist.name
        // A list entry counts ids; a full playlist counts the songs it can
        // actually show, so the two agree with `entry`.
        songCount = songs?.count ?? playlist.trackIDs.count
        duration = Int((songs?.reduce(0) { $0 + $1.duration } ?? playlist.duration).rounded())
        created = playlist.updatedAt.map(Timestamp.string)
        changed = created
        coverArt = playlist.artworkID ?? songs?.compactMap(\.artworkID).first
        entry = songs?.map { SongItem($0) }
    }
}

struct Starred: Encodable, Sendable {
    var artist: [ArtistItem]
    var album: [AlbumItem]
    var song: [SongItem]
}

/// `getGenres`. The protocol's `value` is the genre's name.
struct Genres: Encodable, Sendable {
    struct Item: Encodable, Sendable {
        var value: String
        var songCount: Int
        var albumCount: Int
        /// Cadence's own: up to four covers from the genre's albums, for a
        /// tile. Other clients ignore it.
        var cadenceCoverArt: [String]

        init(_ genre: Genre) {
            value = genre.name
            songCount = genre.trackCount
            albumCount = genre.albumCount
            cadenceCoverArt = genre.artworkIDs
        }
    }
    var genre: [Item]
}

/// Cadence's own `getCadenceCatalogs` and `getCadenceCatalog`: the Mac's
/// catalogs, worked out on the Mac. Only what a reader needs: the rules
/// arrive as the one line the Mac shows, not as rules to edit.
struct Catalogs: Encodable, Sendable {
    var catalog: [CatalogItem]
}

struct CatalogItem: Encodable, Sendable {
    var id: String
    var name: String
    /// `Label is ECM and Decade is 1970s`.
    var summary: String
    var albumCount: Int
    /// Up to four covers from the catalog's albums, for a tile.
    var coverArt: [String]
    var changed: String
    /// Present on `getCadenceCatalog`, absent in the list. In the catalog's
    /// own order.
    var album: [AlbumItem]?

    init(_ catalog: Catalog, albums: [Album], context: Catalog.Context, includingAlbums: Bool) {
        id = WireID.catalog(catalog.id)
        name = catalog.name
        summary = catalog.definition.summary(in: context)
        albumCount = albums.count
        coverArt = Catalog.covers(of: albums)
        changed = Timestamp.string(catalog.updatedAt)
        album = includingAlbums ? albums.map { AlbumItem($0, includingSongs: false) } : nil
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
