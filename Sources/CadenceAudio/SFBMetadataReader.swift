import Foundation
import SFBAudioEngine
import CadenceCore

/// `MetadataReader` for every format SFB handles — ALAC, AIFF, WAV, MP3, AAC,
/// Opus, Vorbis, WavPack, Monkey's Audio, and FLAC among them.
///
/// The pure-Swift FLAC reader in `CadenceLibrary` is still the faster path for
/// FLAC and is kept for that reason; this one covers everything else.
///
/// The forgiving parsing that FLAC reader does by hand mostly happens inside
/// SFB here, but not all of it: release dates still arrive as free text, and
/// tag values still arrive with stray whitespace, so those are handled again.
public struct SFBMetadataReader: MetadataReader, Sendable {

    public init() {}

    /// Extensions SFB will decode. Asked at runtime rather than hard-coded, so
    /// the list follows whatever SFB was built with.
    public static var supportedExtensions: Set<String> {
        Set(AudioFile.supportedPathExtensions.map { $0.lowercased() })
    }

    public func readTrack(at url: URL) throws -> Track {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let metadata = file.metadata
        let properties = file.properties

        let artist = Self.clean(metadata.artist) ?? "Unknown Artist"
        let isCompilation = metadata.isCompilation ?? false
        let albumArtist = Self.clean(metadata.albumArtist)
            ?? (isCompilation ? "Various Artists" : artist)

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date) ?? Date()

        return Track(
            url: url,
            title: Self.clean(metadata.title)
                ?? url.deletingPathExtension().lastPathComponent,
            artist: artist,
            albumArtist: albumArtist,
            albumTitle: Self.clean(metadata.albumTitle) ?? "Unknown Album",
            composer: Self.clean(metadata.composer),
            genre: Self.clean(metadata.genre),
            year: Self.year(from: metadata.releaseDate),
            trackNumber: metadata.trackNumber,
            trackCount: metadata.trackTotal,
            discNumber: metadata.discNumber,
            discCount: metadata.discTotal,
            duration: properties.duration ?? 0,
            format: Self.format(properties, url: url),
            artworkID: nil,
            replayGain: Self.replayGain(metadata),
            isCompilation: isCompilation,
            dateAdded: Date(),
            fingerprint: Self.fingerprint(size: size, modified: modified))
    }

    public func readArtwork(at url: URL) throws -> Data? {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let pictures = file.metadata.attachedPictures
        // Prefer the front cover; some files carry a booklet scan or an artist
        // photo first, and using those as the album tile looks like a bug.
        let front = pictures.first { $0.type == .frontCover }
        return (front ?? pictures.first)?.imageData
    }

    /// Tags and cover in one read, for the scanner.
    public func readTrackAndArtwork(at url: URL) throws -> (track: Track, artwork: Data?) {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let pictures = file.metadata.attachedPictures
        let front = pictures.first { $0.type == .frontCover } ?? pictures.first
        return (try readTrack(at: url), front?.imageData)
    }

    // MARK: - Value parsing

    /// Stray whitespace is invisible in a tag editor and very visible in a
    /// library — the same reason the FLAC reader trims.
    static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// `releaseDate` is free text: `1969`, `1969-08-15`, `15/08/1969`.
    static func year(from value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.prefix { $0.isNumber }
        if digits.count == 4, let year = PlausibleYear.validated(Int(digits)) {
            return year
        }
        // Fall back to any four-digit run that reads as a plausible year, for
        // dates written the other way round: "15 August 1999".
        guard let match = value.firstMatch(of: /\d{4}/) else { return nil }
        return PlausibleYear.validated(Int(match.output))
    }

    static func format(_ properties: AudioProperties, url: URL) -> AudioFormat {
        AudioFormat(
            codec: Self.codec(properties.formatName, extension: url.pathExtension),
            sampleRate: properties.sampleRate ?? 44_100,
            bitDepth: properties.bitDepth,
            channelCount: properties.channelCount.map(Int.init) ?? 2,
            // SFB reports this in kbps despite the header calling it KiB/sec.
            bitRate: properties.bitrate.map { Int($0.rounded()) })
    }

    /// SFB's format names are descriptive ("FLAC", "Apple Lossless"), so they
    /// are matched loosely and the extension is the fallback.
    static func codec(_ formatName: String?, extension pathExtension: String) -> AudioFormat.Codec {
        let name = (formatName ?? "").lowercased()
        if name.contains("flac") { return .flac }
        if name.contains("apple lossless") || name.contains("alac") { return .alac }
        if name.contains("aiff") { return .aiff }
        if name.contains("wave") || name == "wav" { return .wav }
        if name.contains("mpeg-1 layer iii") || name.contains("mp3") { return .mp3 }
        if name.contains("aac") || name.contains("mpeg-4") { return .aac }
        if name.contains("opus") { return .opus }
        if name.contains("vorbis") { return .vorbis }

        switch pathExtension.lowercased() {
        case "flac": return .flac
        case "m4a", "alac": return .alac
        case "aif", "aiff", "aifc": return .aiff
        case "wav", "wave": return .wav
        case "mp3": return .mp3
        case "aac", "m4b": return .aac
        case "opus": return .opus
        case "ogg", "oga": return .vorbis
        default: return .other(formatName ?? pathExtension.uppercased())
        }
    }

    /// Qualified: SFBAudioEngine exports a `ReplayGain` of its own.
    static func replayGain(_ metadata: AudioMetadata) -> CadenceCore.ReplayGain? {
        let gain = CadenceCore.ReplayGain(
            trackGain: metadata.replayGainTrackGain,
            trackPeak: metadata.replayGainTrackPeak,
            albumGain: metadata.replayGainAlbumGain,
            albumPeak: metadata.replayGainAlbumPeak)
        return gain.trackGain == nil && gain.albumGain == nil ? nil : gain
    }

    static func fingerprint(size: Int64, modified: Date) -> String {
        "\(size)-\(Int(modified.timeIntervalSince1970))"
    }
}
