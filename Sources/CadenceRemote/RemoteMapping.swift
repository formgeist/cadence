import Foundation
import CadenceCore

/// Where a track from the Mac's library lives, written as a `Track.url`.
///
///     cadence-remote://song/tr-0b1c…?suffix=flac
///
/// It names a song on the paired server and nothing else: no host, no key.
/// `RemoteTrackSource` turns it into a local file. Keeping the server out of
/// it means a track saved in a queue still plays after the Mac's address
/// changes.
public enum RemoteTrackLocation {
    public static let scheme = "cadence-remote"

    public static func url(songID: String, suffix: String?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "song"
        components.path = "/" + songID
        if let suffix, !suffix.isEmpty {
            components.queryItems = [URLQueryItem(name: "suffix", value: suffix)]
        }
        // Only ids and suffixes the server issued get here, and both are
        // plain ASCII, so this does not fail for them.
        return components.url ?? URL(string: "\(scheme)://song/invalid")!
    }

    /// The song id and file extension, or nil for any URL that is not a
    /// remote track's.
    public static func parse(_ url: URL) -> (songID: String, suffix: String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == "song" else { return nil }
        let id = String(components.path.dropFirst())
        // Ids become file names in the cache, so only the characters the
        // server's ids are made of are accepted.
        guard isSafe(id, maximum: 80) else { return nil }
        let suffix = components.queryItems?.first { $0.name == "suffix" }?.value ?? ""
        guard suffix.isEmpty || isSafe(suffix, maximum: 8) else { return nil }
        return (id, suffix.lowercased())
    }

    private static func isSafe(_ text: String, maximum: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= maximum && text.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }
}

// MARK: - Tracks

extension Track {
    /// The song as a track the app can list, queue and play.
    ///
    /// Nil for a song whose id is not one Cadence's server issues: the id is
    /// the Mac's own track id, kept so that the same song is the same track
    /// on both devices.
    ///
    /// - Parameter albumArtist: The album's artist, when the song came with
    ///   its album. A song on its own carries the album artist's name in
    ///   `displayAlbumArtist`. A server too old to send it names only the
    ///   song's own artist, which then stands in: that puts a compilation
    ///   track under its performer until its album is loaded, and
    ///   `albumKey` is then not the album's.
    public init?(remote song: RemoteSong, albumArtist: String? = nil) {
        guard let id = RemoteIDs.uuid(song.id, prefix: "tr-") else { return nil }
        let artist = song.artist ?? ""
        self.init(
            id: id,
            url: RemoteTrackLocation.url(songID: song.id, suffix: song.suffix),
            title: song.title,
            artist: artist,
            albumArtist: albumArtist ?? song.displayAlbumArtist ?? artist,
            albumTitle: song.album ?? "",
            genre: song.genre,
            year: song.year,
            trackNumber: song.track,
            discNumber: song.discNumber,
            duration: TimeInterval(song.duration ?? 0),
            format: AudioFormat(remote: song),
            artworkID: song.coverArt,
            dateAdded: song.created.flatMap(RemoteIDs.date) ?? .distantPast)
    }
}

extension AudioFormat {
    /// What the song says about its file. The extension decides the codec,
    /// except for `m4a`, which holds either ALAC or AAC: a bit depth means
    /// lossless, which means ALAC.
    public init(remote song: RemoteSong) {
        let suffix = song.suffix?.lowercased() ?? ""
        let codec: Codec = switch suffix {
        case "flac": .flac
        case "mp3": .mp3
        case "wav": .wav
        case "aif", "aiff": .aiff
        case "opus": .opus
        case "ogg", "oga": .vorbis
        case "aac": .aac
        case "alac": .alac
        case "m4a", "m4b", "mp4": song.bitDepth != nil ? .alac : .aac
        case "": .other("Unknown")
        default: .other(suffix)
        }
        self.init(codec: codec, sampleRate: Double(song.samplingRate ?? 44_100),
                  bitDepth: song.bitDepth, channelCount: song.channelCount ?? 2,
                  bitRate: song.bitRate)
    }
}

// MARK: - Albums, artists, playlists

extension Album {
    /// The album with its songs, as the app's album. Songs without an id
    /// Cadence issues are left out.
    ///
    /// The album's key is built from the same name, title and year the Mac
    /// keys it by, so `stableID` here is the id the server sent.
    public init(remote album: RemoteAlbum) {
        let albumArtist = album.artist ?? ""
        self.init(
            key: Album.Key(albumArtist: albumArtist, title: album.name, year: album.year),
            tracks: (album.song ?? []).compactMap { Track(remote: $0, albumArtist: albumArtist) })
    }
}

extension Artist {
    /// The server counts albums, not tracks or formats, so those are left
    /// empty until the artist's albums are loaded.
    public init(remote artist: RemoteArtist) {
        self.init(name: artist.name, albumCount: artist.albumCount ?? artist.album?.count ?? 0,
                  trackCount: 0, formats: [])
    }
}

extension Playlist {
    /// Nil for a playlist whose id is not one Cadence's server issues. The
    /// track ids are only there when the playlist came with its songs.
    public init?(remote playlist: RemotePlaylist) {
        guard let id = RemoteIDs.uuid(playlist.id, prefix: "pl-") else { return nil }
        let entries = playlist.entry ?? []
        self.init(
            id: id, name: playlist.name,
            trackIDs: entries.compactMap { RemoteIDs.uuid($0.id, prefix: "tr-") },
            duration: TimeInterval(playlist.duration),
            artworkID: playlist.coverArt,
            updatedAt: (playlist.changed ?? playlist.created).flatMap(RemoteIDs.date))
    }
}

enum RemoteIDs {
    /// The UUID in an id such as `tr-0b1c…`, or nil.
    static func uuid(_ id: String, prefix: String) -> UUID? {
        guard id.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(prefix.count)))
    }

    static func date(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }
}
