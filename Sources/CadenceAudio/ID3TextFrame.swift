import Foundation

/// Reads one text frame straight out of a file's leading ID3v2 tag.
///
/// ID3v2.4 stores several values in one text frame, separated by nulls —
/// `TCOM` holding four composers, say. TagLib's `toString()`, which SFB uses
/// for every frame, joins those with a single space, so four names arrive as
/// one run-on name that no one can split back apart. Reading the frame here
/// keeps the separators.
///
/// Deliberately narrow: v2.3 and v2.4 only, at the start of the file, and it
/// gives up (returns nil) on anything unusual — a whole-tag unsynchronisation,
/// a compressed or encrypted frame — so the caller falls back to SFB's value.
enum ID3TextFrame {

    static func values(of frameID: String, at url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 10), header.count == 10 else { return nil }
        let head = [UInt8](header)
        guard head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 else { return nil }  // "ID3"
        let version = head[3]
        guard version == 3 || version == 4 else { return nil }
        let flags = head[5]
        guard flags & 0x80 == 0 else { return nil }

        let size = synchsafe(head[6..<10])
        guard let body = try? handle.read(upToCount: size) else { return nil }
        return frame(frameID, in: [UInt8](body), version: version,
                     hasExtendedHeader: flags & 0x40 != 0)
    }

    /// The tag body after its 10-byte header. Split out so it can be tested
    /// without a file.
    static func frame(_ frameID: String, in tag: [UInt8], version: UInt8,
                      hasExtendedHeader: Bool) -> [String]? {
        var offset = 0
        if hasExtendedHeader {
            guard tag.count >= 4 else { return nil }
            // v2.4 counts the size field itself; v2.3 does not.
            offset = version == 4 ? synchsafe(tag[0..<4]) : bigEndian(tag[0..<4]) + 4
        }
        let wanted = Array(frameID.utf8)

        while offset + 10 <= tag.count {
            let id = Array(tag[offset..<offset + 4])
            if id[0] == 0 { break }  // padding
            let sizeBytes = tag[offset + 4..<offset + 8]
            let frameSize = version == 4 ? synchsafe(sizeBytes) : bigEndian(sizeBytes)
            let start = offset + 10
            guard frameSize >= 0, start + frameSize <= tag.count else { return nil }

            if id == wanted {
                // Compression, encryption, unsynchronisation, data-length
                // indicator: none of them worth handling for a text frame.
                guard tag[offset + 9] == 0 else { return nil }
                return decode(Array(tag[start..<start + frameSize]))
            }
            offset = start + frameSize
        }
        return nil
    }

    /// One encoding byte, then the text; values separated by a null of the
    /// encoding's width.
    static func decode(_ frame: [UInt8]) -> [String]? {
        guard let encoding = frame.first else { return nil }
        let text = Array(frame.dropFirst())
        let width = encoding == 1 || encoding == 2 ? 2 : 1
        let stringEncoding: String.Encoding = switch encoding {
        case 0: .isoLatin1
        case 1: .utf16          // each value carries its own BOM
        case 2: .utf16BigEndian
        default: .utf8
        }

        var values: [String] = []
        var start = 0
        var index = 0
        func flush(upTo end: Int) {
            guard end > start else { return }
            if let value = String(bytes: text[start..<end], encoding: stringEncoding)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                values.append(value)
            }
        }
        while index + width <= text.count {
            if text[index..<index + width].allSatisfy({ $0 == 0 }) {
                flush(upTo: index)
                start = index + width
            }
            index += width
        }
        flush(upTo: text.count)
        return values.isEmpty ? nil : values
    }

    private static func synchsafe(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 8 | Int($1) }
    }
}
