import Foundation
import GRDB
import CadenceCore

/// Row mapping for `Track`. Kept separate from the model so `CadenceCore` never
/// learns what a database is — PLAN.md §4, rule 1.
struct TrackRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "track"

    var id: String
    var url: String
    var bookmark: Data?

    var title: String
    var artist: String
    var albumArtist: String
    var albumTitle: String
    var composer: String?
    var genre: String?
    var year: Int?

    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?

    var duration: Double
    var codec: String
    var sampleRate: Double
    var bitDepth: Int?
    var channelCount: Int

    var artworkID: String?
    var replayGainTrack: Double?
    var replayGainTrackPeak: Double?
    var replayGainAlbum: Double?
    var replayGainAlbumPeak: Double?

    var isCompilation: Bool
    var dateAdded: Date
    var fingerprint: String?
    var fileSize: Int64

    init(_ track: Track, fileSize: Int64 = 0) {
        id = track.id.uuidString
        url = track.url.absoluteString
        bookmark = track.bookmark
        title = track.title
        artist = track.artist
        albumArtist = track.albumArtist
        albumTitle = track.albumTitle
        composer = track.composer
        genre = track.genre
        year = track.year
        trackNumber = track.trackNumber
        trackCount = track.trackCount
        discNumber = track.discNumber
        discCount = track.discCount
        duration = track.duration
        codec = track.format.codec.name
        sampleRate = track.format.sampleRate
        bitDepth = track.format.bitDepth
        channelCount = track.format.channelCount
        artworkID = track.artworkID
        replayGainTrack = track.replayGain?.trackGain
        replayGainTrackPeak = track.replayGain?.trackPeak
        replayGainAlbum = track.replayGain?.albumGain
        replayGainAlbumPeak = track.replayGain?.albumPeak
        isCompilation = track.isCompilation
        dateAdded = track.dateAdded
        fingerprint = track.fingerprint
        self.fileSize = fileSize
    }

    var track: Track {
        Track(
            id: UUID(uuidString: id) ?? UUID(),
            url: URL(string: url) ?? URL(fileURLWithPath: url),
            bookmark: bookmark,
            title: title,
            artist: artist,
            albumArtist: albumArtist,
            albumTitle: albumTitle,
            composer: composer,
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            trackCount: trackCount,
            discNumber: discNumber,
            discCount: discCount,
            duration: duration,
            format: AudioFormat(
                codec: AudioFormat.Codec(name: codec),
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                channelCount: channelCount),
            artworkID: artworkID,
            replayGain: hasReplayGain
                ? ReplayGain(trackGain: replayGainTrack,
                             trackPeak: replayGainTrackPeak,
                             albumGain: replayGainAlbum,
                             albumPeak: replayGainAlbumPeak)
                : nil,
            isCompilation: isCompilation,
            dateAdded: dateAdded,
            fingerprint: fingerprint)
    }

    private var hasReplayGain: Bool {
        replayGainTrack != nil || replayGainAlbum != nil
    }
}
