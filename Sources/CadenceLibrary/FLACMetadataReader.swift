import Foundation
import CadenceCore

public enum MetadataError: Error, Equatable {
    case notFLAC(URL)
    case truncated(URL)
}

/// Reads FLAC tags without an audio library.
///
/// PLAN.md §3 puts metadata behind SFBAudioEngine, and for the other formats it
/// still should. But FLAC's metadata blocks are simple enough to parse
/// directly, and doing so means import works before the audio layer compiles —
/// which is the whole reason the protocol boundary exists.
///
/// The parsers are deliberately forgiving. Files in the wild break the spec
/// constantly: `TRACKNUMBER=3/12`, repeated `ARTIST` fields,
/// `DATE=1969-08-15`, gain tags carrying their units, tags that aren't valid
/// UTF-8. Each of those is handled here rather than in the importer, with a
/// test per case — PLAN.md §7.
public struct FLACMetadataReader: MetadataReader, Sendable {

    public init() {}

    // MARK: - MetadataReader

    public func readTrack(at url: URL) throws -> Track {
        try makeTrack(url: url, blocks: Self.readBlocks(at: url, wantPicture: false))
    }

    private func makeTrack(url: URL, blocks: Blocks) throws -> Track {
        let comments = blocks.comments
        let stream = blocks.streamInfo

        let artists = comments.values(for: "ARTIST")
        let artist = artists.isEmpty
            ? "Unknown Artist"
            : artists.joined(separator: ", ")

        let (trackNumber, trackTotal) = Self.splitIndex(comments.value(for: "TRACKNUMBER"))
        let (discNumber, discTotal) = Self.splitIndex(comments.value(for: "DISCNUMBER"))

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date) ?? Date()
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        return Track(
            url: url,
            title: comments.value(for: "TITLE")
                ?? url.deletingPathExtension().lastPathComponent,
            artist: artist,
            albumArtist: comments.value(for: "ALBUMARTIST")
                ?? comments.value(for: "ALBUM ARTIST")
                // A compilation with no ALBUMARTIST is Various Artists, not
                // an album by whoever happens to be on track one.
                ?? (Self.isCompilation(comments) ? "Various Artists" : artists.first)
                ?? artist,
            albumTitle: Self.albumTitle(
                comments.value(for: "ALBUM") ?? "Unknown Album",
                discNumber: discNumber),
            composer: comments.value(for: "COMPOSER"),
            genre: comments.value(for: "GENRE"),
            year: Self.year(from: comments.value(for: "DATE")
                ?? comments.value(for: "YEAR")),
            trackNumber: trackNumber,
            trackCount: trackTotal
                ?? Self.integer(comments.value(for: "TRACKTOTAL"))
                ?? Self.integer(comments.value(for: "TOTALTRACKS")),
            discNumber: discNumber,
            discCount: discTotal
                ?? Self.integer(comments.value(for: "DISCTOTAL"))
                ?? Self.integer(comments.value(for: "TOTALDISCS")),
            duration: stream.duration,
            format: AudioFormat(
                codec: .flac,
                sampleRate: stream.sampleRate,
                bitDepth: stream.bitDepth,
                channelCount: stream.channelCount),
            artworkID: nil,
            replayGain: Self.replayGain(comments),
            isCompilation: Self.isCompilation(comments),
            dateAdded: Date(),
            fingerprint: Self.fingerprint(size: size, modified: modified))
    }

    public func readArtwork(at url: URL) throws -> Data? {
        try Self.readBlocks(at: url, wantPicture: true).picture
    }

    /// Tags and cover in a single pass. The scanner wants both for every file,
    /// and reading the blocks twice doubles the syscalls across a whole
    /// library for no benefit.
    public func readTrackAndArtwork(at url: URL) throws -> (track: Track, artwork: Data?) {
        let blocks = try Self.readBlocks(at: url, wantPicture: true)
        return (try makeTrack(url: url, blocks: blocks), blocks.picture)
    }

    /// Size plus modification time. Cheap enough to run over a whole folder,
    /// and enough to skip files that have not changed since the last import.
    public static func fingerprint(size: Int64, modified: Date) -> String {
        "\(size)-\(Int(modified.timeIntervalSince1970))"
    }

    public static func fingerprint(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        return fingerprint(size: size, modified: modified)
    }

    // MARK: - Block parsing

    struct StreamInfo {
        var sampleRate: Double = 44_100
        var bitDepth: Int? = 16
        var channelCount: Int = 2
        var duration: TimeInterval = 0
    }

    struct Blocks {
        var streamInfo = StreamInfo()
        var comments = VorbisComments()
        var picture: Data?
    }

    /// Reads only the metadata blocks, then stops — never the audio. A large
    /// library is scanned by touching a few kilobytes per file.
    static func readBlocks(at url: URL, wantPicture: Bool) throws -> Blocks {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let magic = try handle.read(upToCount: 4), magic == Data("fLaC".utf8) else {
            throw MetadataError.notFLAC(url)
        }

        var blocks = Blocks()
        var isLast = false

        while !isLast {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else {
                throw MetadataError.truncated(url)
            }
            isLast = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7F
            let length = Int(header[header.startIndex + 1]) << 16
                | Int(header[header.startIndex + 2]) << 8
                | Int(header[header.startIndex + 3])

            // Skipping is a seek, not a read, so a 10 MB embedded cover costs
            // nothing when we only want tags.
            let wanted = type == 0 || type == 4 || (wantPicture && type == 6)
            guard wanted else {
                try handle.seek(toOffset: handle.offset() + UInt64(length))
                continue
            }

            guard let body = try handle.read(upToCount: length), body.count == length else {
                throw MetadataError.truncated(url)
            }

            switch type {
            case 0: blocks.streamInfo = parseStreamInfo(body)
            case 4: blocks.comments = parseVorbisComments(body)
            case 6: blocks.picture = blocks.picture ?? parsePicture(body)
            default: break
            }
        }

        return blocks
    }

    /// STREAMINFO packs sample rate, channels, bit depth and total samples into
    /// eight bytes of bit fields.
    static func parseStreamInfo(_ data: Data) -> StreamInfo {
        var info = StreamInfo()
        guard data.count >= 18 else { return info }
        let bytes = [UInt8](data)

        let rate = UInt32(bytes[10]) << 12 | UInt32(bytes[11]) << 4 | UInt32(bytes[12]) >> 4
        let channels = Int((bytes[12] >> 1) & 0x07) + 1
        let depth = Int(((UInt16(bytes[12]) & 0x01) << 4) | (UInt16(bytes[13]) >> 4)) + 1

        var samples: UInt64 = UInt64(bytes[13] & 0x0F)
        for index in 14...17 { samples = samples << 8 | UInt64(bytes[index]) }

        // A rate of zero is a broken file, not a valid stream; leaving the
        // default beats dividing by it.
        if rate > 0 { info.sampleRate = Double(rate) }
        info.channelCount = channels
        info.bitDepth = depth
        info.duration = rate > 0 ? Double(samples) / Double(rate) : 0
        return info
    }

    static func parseVorbisComments(_ data: Data) -> VorbisComments {
        var comments = VorbisComments()
        var cursor = Cursor(data)

        guard let vendorLength = cursor.readUInt32LE() else { return comments }
        cursor.skip(Int(vendorLength))
        guard let count = cursor.readUInt32LE() else { return comments }

        for _ in 0..<count {
            guard let length = cursor.readUInt32LE(),
                  let field = cursor.read(Int(length)) else { break }
            // Spec says UTF-8. Files say otherwise often enough that falling
            // back beats dropping the tag.
            let text = String(data: field, encoding: .utf8)
                ?? String(data: field, encoding: .isoLatin1)
            guard let text, let separator = text.firstIndex(of: "=") else { continue }
            let key = String(text[text.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces).uppercased()
            // Stray whitespace around a value is invisible in a tag editor and
            // very visible in a library: " Korn" and "Korn" are two artists.
            let value = String(text[text.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            comments.append(key: key, value: value)
        }
        return comments
    }

    static func parsePicture(_ data: Data) -> Data? {
        var cursor = Cursor(data)
        cursor.skip(4)                                        // picture type
        guard let mimeLength = cursor.readUInt32BE() else { return nil }
        cursor.skip(Int(mimeLength))
        guard let descriptionLength = cursor.readUInt32BE() else { return nil }
        cursor.skip(Int(descriptionLength))
        cursor.skip(16)                                       // w, h, depth, colours
        guard let dataLength = cursor.readUInt32BE() else { return nil }
        return cursor.read(Int(dataLength))
    }

    // MARK: - Forgiving value parsers

    /// Rippers that split a multi-disc release sometimes fold the disc index
    /// into the album title — `Kid A (1)`, `Kid A (2)` — which shows up as two
    /// albums where there is one.
    ///
    /// The suffix is only dropped when `DISCNUMBER` agrees with it, so an album
    /// genuinely called `Untitled (2)` on disc one keeps its name. Without that
    /// check this would be guesswork; with it, the file is contradicting
    /// itself and the disc tag is the more reliable half.
    static func albumTitle(_ raw: String, discNumber: Int?) -> String {
        guard let discNumber else { return raw }
        let pattern = /^(?<title>.+?)\s*\((?<disc>\d{1,2})\)$/
        guard let match = raw.wholeMatch(of: pattern),
              Int(match.disc) == discNumber else { return raw }
        let stripped = String(match.title).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? raw : stripped
    }

    /// `3/12` → `(3, 12)`, `03` → `(3, nil)`, junk → `(nil, nil)`.
    static func splitIndex(_ value: String?) -> (Int?, Int?) {
        guard let value else { return (nil, nil) }
        let parts = value.split(separator: "/", maxSplits: 1)
        guard let first = parts.first else { return (nil, nil) }
        return (integer(String(first)),
                parts.count > 1 ? integer(String(parts[1])) : nil)
    }

    /// `1969-08-15`, `1969/08`, `1969` → `1969`. Anything without four leading
    /// digits is not a year we can trust.
    static func year(from value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.prefix { $0.isNumber }
        guard digits.count == 4, let year = Int(digits) else { return nil }
        return year
    }

    /// `-6.40 dB` → `-6.4`. The unit is part of the tag in most encoders.
    static func decibels(_ value: String?) -> Double? {
        guard let value else { return nil }
        let scanner = Scanner(string: value.trimmingCharacters(in: .whitespaces))
        return scanner.scanDouble()
    }

    static func integer(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    static func replayGain(_ comments: VorbisComments) -> ReplayGain? {
        let gain = ReplayGain(
            trackGain: decibels(comments.value(for: "REPLAYGAIN_TRACK_GAIN")),
            trackPeak: decibels(comments.value(for: "REPLAYGAIN_TRACK_PEAK")),
            albumGain: decibels(comments.value(for: "REPLAYGAIN_ALBUM_GAIN")),
            albumPeak: decibels(comments.value(for: "REPLAYGAIN_ALBUM_PEAK")))
        return gain.trackGain == nil && gain.albumGain == nil ? nil : gain
    }

    static func isCompilation(_ comments: VorbisComments) -> Bool {
        for key in ["COMPILATION", "ITUNESCOMPILATION"] {
            if let value = comments.value(for: key), value != "0",
               value.lowercased() != "false" {
                return true
            }
        }
        return comments.value(for: "ALBUMARTIST")?.lowercased() == "various artists"
    }
}

// MARK: - Comment storage

/// Vorbis comments allow repeated keys — several `ARTIST` fields on one track
/// is normal, not corruption — so values are kept as a list per key.
public struct VorbisComments: Equatable, Sendable {
    private var storage: [String: [String]] = [:]

    public init() {}

    mutating func append(key: String, value: String) {
        storage[key, default: []].append(value)
    }

    public func value(for key: String) -> String? {
        storage[key.uppercased()]?.first
    }

    public func values(for key: String) -> [String] {
        storage[key.uppercased()] ?? []
    }

    public var keys: [String] { Array(storage.keys) }
}

// MARK: - Byte cursor

private struct Cursor {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func skip(_ count: Int) { offset = min(offset + count, data.endIndex) }

    mutating func read(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    mutating func readUInt32LE() -> UInt32? {
        guard let bytes = read(4).map([UInt8].init) else { return nil }
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    mutating func readUInt32BE() -> UInt32? {
        guard let bytes = read(4).map([UInt8].init) else { return nil }
        return UInt32(bytes[3]) | UInt32(bytes[2]) << 8
            | UInt32(bytes[1]) << 16 | UInt32(bytes[0]) << 24
    }
}
