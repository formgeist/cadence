import Foundation

/// Part of a file, to be sent as a response body without reading it into
/// memory first. A lossless album track is tens of megabytes and a client may
/// ask for several at once.
public struct FileBody: Sendable, Equatable {
    public var url: URL
    public var offset: UInt64
    public var length: UInt64

    public init(url: URL, offset: UInt64, length: UInt64) {
        self.url = url
        self.offset = offset
        self.length = length
    }
}

/// What a `Range` header asks for, measured against a file of a known size.
///
/// Only the form a player uses to seek is honoured: one range, in bytes.
/// Anything else is ignored and answered with the whole file, which RFC 9110
/// permits and which keeps the arithmetic here to one case. Every result is
/// already inside the file: nothing downstream needs to check bounds again.
public enum ByteRange: Sendable, Equatable {
    /// No usable range: send everything.
    case whole
    case partial(offset: UInt64, length: UInt64)
    /// A well-formed range that lies outside the file.
    case unsatisfiable

    public static func resolve(_ header: String?, size: UInt64) -> ByteRange {
        guard let header else { return .whole }
        let prefix = "bytes="
        guard header.hasPrefix(prefix) else { return .whole }
        let spec = header.dropFirst(prefix.count)
        // Several ranges would need a multipart answer. Not offered.
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = spec[..<dash]
        let last = spec[spec.index(after: dash)...]

        switch (first.isEmpty, last.isEmpty) {
        case (true, true):
            return .whole
        case (true, false):
            // `-n`: the last n bytes.
            guard let count = number(last) else { return .whole }
            guard count > 0, size > 0 else { return .unsatisfiable }
            let length = min(count, size)
            return .partial(offset: size - length, length: length)
        case (false, true):
            // `a-`: from a to the end.
            guard let start = number(first) else { return .whole }
            guard start < size else { return .unsatisfiable }
            return .partial(offset: start, length: size - start)
        case (false, false):
            guard let start = number(first), let end = number(last), start <= end else {
                return .whole
            }
            guard start < size else { return .unsatisfiable }
            // An end past the file is brought back to its last byte.
            return .partial(offset: start, length: min(end, size - 1) - start + 1)
        }
    }

    /// Digits only, and few enough that the value cannot overflow.
    private static func number(_ text: Substring) -> UInt64? {
        guard !text.isEmpty, text.count <= 18,
              text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(text)
    }
}

/// Opens library files for reading, and nothing else.
enum FileSource {

    /// A regular file, opened read-only, with its size.
    ///
    /// `O_NOFOLLOW` and the regular-file check matter because the path was
    /// true when the library was scanned, not necessarily now. If the file
    /// has since been swapped for a symbolic link, a device or a directory,
    /// this refuses it, so the server can only ever send what the scanner
    /// actually read.
    static func open(_ url: URL) -> (handle: FileHandle, size: UInt64)? {
        guard url.isFileURL else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
            close(descriptor)
            return nil
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                UInt64(status.st_size))
    }

    static func size(of url: URL) -> UInt64? {
        guard let opened = open(url) else { return nil }
        try? opened.handle.close()
        return opened.size
    }
}
