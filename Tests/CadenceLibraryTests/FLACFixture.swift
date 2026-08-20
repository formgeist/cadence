import Foundation

/// Builds real FLAC files to scan.
///
/// PLAN.md §2 step 5 calls an integration test over actual FLAC files the
/// highest-value test in the project, and it is right: import correctness is
/// what everything downstream depends on. Hand-written byte blobs would only
/// prove the parser agrees with itself, so these are encoded by `afconvert`,
/// which ships with macOS, and then re-tagged here.
enum FLACFixture {

    struct Spec {
        var name: String
        var tags: [(String, String)]
        var seconds: Double = 0.4
        var sampleRate: Int = 44_100
        var bitDepth: Int = 16
        var channels: Int = 2
        var picture: Data?
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert")
    }

    /// Writes every spec into `directory`, encoding one base file per audio
    /// format and re-tagging it, so a fixture set of twenty costs two encodes.
    @discardableResult
    static func build(_ specs: [Spec], in directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        var bases: [String: Data] = [:]
        var written: [URL] = []

        for spec in specs {
            let key = "\(spec.seconds)-\(spec.sampleRate)-\(spec.bitDepth)-\(spec.channels)"
            let base: Data
            if let cached = bases[key] {
                base = cached
            } else {
                base = try encodeBase(spec, in: directory)
                bases[key] = base
            }

            let url = directory.appendingPathComponent("\(spec.name).flac")
            try retag(base, tags: spec.tags, picture: spec.picture).write(to: url)
            written.append(url)
        }
        return written
    }

    // MARK: - Encoding

    private static func encodeBase(_ spec: Spec, in directory: URL) throws -> Data {
        let wav = directory.appendingPathComponent("_base-\(UUID().uuidString).wav")
        let flac = wav.deletingPathExtension().appendingPathExtension("flac")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: flac)
        }

        try makeWAV(spec, at: wav)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "flac", "-d", "flac", wav.path, flac.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        return try Data(contentsOf: flac)
    }

    private static func makeWAV(_ spec: Spec, at url: URL) throws {
        let bytesPerSample = spec.bitDepth / 8
        let frameCount = Int(spec.seconds * Double(spec.sampleRate))
        var samples = Data()
        samples.reserveCapacity(frameCount * spec.channels * bytesPerSample)

        let peak = Double((1 << (spec.bitDepth - 1)) - 1)
        for frame in 0..<frameCount {
            let value = Int32(0.2 * sin(2 * .pi * 440 * Double(frame)
                                        / Double(spec.sampleRate)) * peak)
            for _ in 0..<spec.channels {
                withUnsafeBytes(of: value.littleEndian) { raw in
                    samples.append(contentsOf: raw.prefix(bytesPerSample))
                }
            }
        }

        let byteRate = spec.sampleRate * spec.channels * bytesPerSample
        var file = Data("RIFF".utf8)
        file += uint32LE(UInt32(36 + samples.count))
        file += Data("WAVEfmt ".utf8)
        file += uint32LE(16)
        file += uint16LE(1)                                    // PCM
        file += uint16LE(UInt16(spec.channels))
        file += uint32LE(UInt32(spec.sampleRate))
        file += uint32LE(UInt32(byteRate))
        file += uint16LE(UInt16(spec.channels * bytesPerSample))
        file += uint16LE(UInt16(spec.bitDepth))
        file += Data("data".utf8)
        file += uint32LE(UInt32(samples.count))
        file += samples

        try file.write(to: url)
    }

    // MARK: - Tagging

    /// Rebuilds the file as STREAMINFO + our VORBIS_COMMENT + optional PICTURE
    /// + the original audio frames, dropping whatever blocks the encoder wrote.
    static func retag(_ source: Data, tags: [(String, String)], picture: Data?) throws -> Data {
        let bytes = [UInt8](source)
        precondition(bytes.count > 4 && Array(bytes[0..<4]) == Array("fLaC".utf8),
                     "fixture base is not a FLAC file — is afconvert present?")

        var offset = 4
        var streamInfo: Data?
        while offset + 4 <= bytes.count {
            let header = bytes[offset]
            let length = Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let bodyStart = offset + 4
            if header & 0x7F == 0 {
                streamInfo = Data(bytes[bodyStart..<(bodyStart + length)])
            }
            offset = bodyStart + length
            if header & 0x80 != 0 { break }
        }

        guard let streamInfo else { return source }
        let audio = Data(bytes[offset...])

        var output = Data("fLaC".utf8)
        output += block(type: 0, body: streamInfo, isLast: false)
        output += block(type: 4, body: vorbisComment(tags), isLast: picture == nil)
        if let picture {
            output += block(type: 6, body: pictureBlock(picture), isLast: true)
        }
        output += audio
        return output
    }

    private static func block(type: UInt8, body: Data, isLast: Bool) -> Data {
        var header = Data([type | (isLast ? 0x80 : 0)])
        let length = body.count
        header += Data([UInt8((length >> 16) & 0xFF),
                        UInt8((length >> 8) & 0xFF),
                        UInt8(length & 0xFF)])
        return header + body
    }

    private static func vorbisComment(_ tags: [(String, String)]) -> Data {
        let vendor = Data("Cadence fixtures".utf8)
        var body = uint32LE(UInt32(vendor.count)) + vendor
        body += uint32LE(UInt32(tags.count))
        for (key, value) in tags {
            let entry = Data("\(key)=\(value)".utf8)
            body += uint32LE(UInt32(entry.count)) + entry
        }
        return body
    }

    private static func pictureBlock(_ image: Data) -> Data {
        let mime = Data("image/png".utf8)
        let description = Data()
        var body = uint32BE(3)                                 // front cover
        body += uint32BE(UInt32(mime.count)) + mime
        body += uint32BE(UInt32(description.count)) + description
        body += uint32BE(8) + uint32BE(8)                       // width, height
        body += uint32BE(32) + uint32BE(0)                      // depth, palette
        body += uint32BE(UInt32(image.count)) + image
        return body
    }

    /// A tiny but genuine PNG, so ImageIO can actually make a thumbnail of it.
    static let samplePNG: Data = {
        let base64 = """
        iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAHUlEQVQoz2P8//8/AzGAiYFI\
        MKpwVOGowlGFowoBAAWBAwsGCPzsAAAAAElFTkSuQmCC
        """
        return Data(base64Encoded: base64.replacingOccurrences(of: "\\", with: "")) ?? Data()
    }()

    // MARK: - Byte helpers

    private static func uint16LE(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
