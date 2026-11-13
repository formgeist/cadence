import Foundation
import CryptoKit

/// A device that has been paired with this Mac and may read its library.
public struct PairedDevice: Codable, Sendable, Identifiable, Equatable {
    public typealias ID = UUID

    public var id: ID
    /// What the device called itself when it paired, cleaned up for display.
    public var name: String
    /// SHA-256 of the device's API key. The key itself is not kept anywhere
    /// on the Mac: it is shown to the device once, at pairing.
    var keyDigest: Data
    public var pairedAt: Date
    /// The last time the device made an authenticated request, to the nearest
    /// minute or so. Nil until it has made one.
    public var lastSeenAt: Date?
}

/// The devices paired with this Mac, and the only place their keys are
/// checked.
///
/// **What is stored.** For each device: an id, a name, two dates, and the
/// SHA-256 of its key. Not the key. A copy of this file is not a way in.
///
/// A plain SHA-256 is enough here, where it would not be for a password,
/// because the key is 256 bits from the system's random generator. There is
/// nothing to guess faster than trying keys, so a deliberately slow hash
/// would only slow the server.
///
/// **Revoking is immediate.** Every request asks this actor, and a revoked
/// device is gone from its memory before `revoke` returns. There is no cache
/// of earlier answers anywhere for a revoked key to live on in.
///
/// **Where.** One JSON file, readable by the user alone, kept apart from the
/// library database: resetting or replacing a library should not unpair
/// every phone, and the library has no business holding credentials.
public actor PairedDeviceStore: Authenticator {

    public enum StoreError: Error, Equatable {
        /// The file exists but is not one this version can read. Nothing is
        /// overwritten: the caller decides what to do with it.
        case unreadable
        case tooManyDevices
        case unknownDevice
    }

    /// More than any household needs, and few enough that the list stays one
    /// a person can read through and prune.
    public static let maximumDevices = 32
    public static let maximumNameLength = 64

    private struct File: Codable {
        var version = 1
        var devices: [PairedDevice]
    }

    private let fileURL: URL
    private var devices: [PairedDevice.ID: PairedDevice] = [:]
    /// Digest to device, so a check is one lookup however many are paired.
    private var byDigest: [Data: PairedDevice.ID] = [:]
    private var lastSeenWrittenAt = Date.distantPast
    private let now: @Sendable () -> Date

    /// Opens the store at `fileURL`, which need not exist yet.
    public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init) throws {
        self.fileURL = fileURL
        self.now = now
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? Self.decoder.decode(File.self, from: data),
              file.version == 1 else { throw StoreError.unreadable }
        for device in file.devices {
            devices[device.id] = device
            byDigest[device.keyDigest] = device.id
        }
    }

    /// `~/Library/Application Support/Cadence/paired-devices.json`
    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent("paired-devices.json")
    }

    // MARK: - Reading

    /// Every paired device, oldest pairing first.
    public func all() -> [PairedDevice] {
        devices.values.sorted {
            $0.pairedAt != $1.pairedAt ? $0.pairedAt < $1.pairedAt
                : $0.id.uuidString < $1.id.uuidString
        }
    }

    public func device(forAPIKey apiKey: String) async -> PairedDevice.ID? {
        // The lookup is by the digest of whatever was sent. Its timing
        // depends on that digest, which an attacker cannot steer towards a
        // stored one without already knowing the key.
        let digest = Data(SHA256.hash(data: Data(apiKey.utf8)))
        guard let id = byDigest[digest], devices[id] != nil else { return nil }
        noteSeen(id)
        return id
    }

    // MARK: - Pairing and revoking

    /// Adds a device and returns the key it must present from now on. This is
    /// the only moment the key exists on the Mac; it is not stored and cannot
    /// be shown again.
    public func pair(named name: String) throws -> (device: PairedDevice, apiKey: String) {
        guard devices.count < Self.maximumDevices else { throw StoreError.tooManyDevices }

        var bytes = [UInt8](repeating: 0, count: 32)
        // A key that is not random is no key. If the generator fails, stop.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("The system random generator is unavailable.")
        }
        let apiKey = Self.base64URL(Data(bytes))

        let device = PairedDevice(
            id: UUID(), name: Self.cleaned(name),
            keyDigest: Data(SHA256.hash(data: Data(apiKey.utf8))),
            pairedAt: now(), lastSeenAt: nil)
        devices[device.id] = device
        byDigest[device.keyDigest] = device.id
        do {
            try save()
        } catch {
            // Not saved means not paired: a device must not hold a key that
            // stops working when the app is next launched.
            devices[device.id] = nil
            byDigest[device.keyDigest] = nil
            throw error
        }
        return (device, apiKey)
    }

    /// Removes a device. Its key stops working before this returns, whether
    /// or not the file could be rewritten.
    public func revoke(_ id: PairedDevice.ID) throws {
        guard let device = devices.removeValue(forKey: id) else {
            throw StoreError.unknownDevice
        }
        byDigest[device.keyDigest] = nil
        try save()
    }

    // MARK: - Last seen

    /// Records the request in memory, and on disk at most once a minute. A
    /// client browsing a library makes requests by the dozen, and "last seen"
    /// is read by a person, not a program.
    private func noteSeen(_ id: PairedDevice.ID) {
        let moment = now()
        devices[id]?.lastSeenAt = moment
        guard moment.timeIntervalSince(lastSeenWrittenAt) >= 60 else { return }
        lastSeenWrittenAt = moment
        try? save()
    }

    // MARK: - File

    /// Writes the whole file to a new path that only the user can read, then
    /// moves it into place, so the file is never half-written and never
    /// readable by anyone else, even for a moment.
    private func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(File(devices: all()))

        let temporary = directory.appendingPathComponent(".paired-devices-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: data,
            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return decoder
    }()

    // MARK: - Pieces

    /// A name comes from the device being paired, which is to say from the
    /// network. It ends up in the Mac's settings window, so it is cut to a
    /// sensible length and stripped of anything that is not text.
    static func cleaned(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.newlines.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        }
        let trimmed = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespaces)
        let cut = String(trimmed.prefix(maximumNameLength))
        return cut.isEmpty ? "Unnamed device" : cut
    }

    /// Base64 with the URL-safe alphabet and no padding: a key travels in a
    /// query string, where `+`, `/` and `=` would each need escaping.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
