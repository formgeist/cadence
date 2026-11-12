import Foundation

/// A short note kept against a record or a song: where you were when you
/// first heard it, who gave it to you, why it matters. Written once, read
/// later — on the album, on Home, and on the album of the day when it comes
/// back round.
///
/// Like `PlayRecord`, a memory names what it is about rather than pointing at
/// a track id, so it survives a rescan, a moved folder or a re-imported file.
/// A note is worth more than a play count; losing one because a folder was
/// re-added would be the worst kind of data loss this app could have.
public struct Memory: Identifiable, Hashable, Sendable {
    /// What the note is about.
    public enum Subject: Hashable, Sendable {
        case album(Album.Key)
        /// A song on a record. The album is part of its identity: the same
        /// song on a live album and a studio album are different memories.
        case track(title: String, artist: String, album: Album.Key)

        public init(track: Track) {
            self = .track(title: track.title, artist: track.artist, album: track.albumKey)
        }

        /// The record the note belongs to, for a track note as well.
        public var albumKey: Album.Key {
            switch self {
            case .album(let key): key
            case .track(_, _, let album): album
            }
        }

        /// The song's title, or nil for a note on the whole record.
        public var trackTitle: String? {
            if case .track(let title, _, _) = self { return title }
            return nil
        }

        /// Whether this note is about `track`.
        public func matches(_ track: Track) -> Bool {
            self == Subject(track: track)
        }
    }

    public var id: UUID
    public var subject: Subject
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date

    /// "Small" is the point — a note, not an essay. Long enough for a few
    /// sentences; enforced by the editor and again by `cleaned`.
    public static let maximumLength = 500

    public init(id: UUID = UUID(), subject: Subject, text: String,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.subject = subject
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Trimmed and capped, or nil when nothing is left — an empty memory is
    /// not saved, it is discarded.
    public static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }

    /// Newest first, the order an album page lists its notes in.
    public static func newestFirst(_ a: Memory, _ b: Memory) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// The memories Home brings back today: up to `limit`, the same all day
    /// and different tomorrow, the way the album of the day is. Notes written
    /// in the last day are left out while older ones exist — Home is for
    /// coming back to things, not for repeating what you just typed.
    ///
    /// `isAvailable` lets the caller drop notes whose record has left the
    /// library: a card that opens nothing is worse than no card.
    public static func resurfaced(from memories: [Memory], now: Date, limit: Int = 3,
                                  calendar: Calendar = .current,
                                  isAvailable: (Memory) -> Bool = { _ in true }) -> [Memory] {
        let available = memories.filter(isAvailable)
        guard !available.isEmpty, limit > 0 else { return [] }
        let settled = available.filter { now.timeIntervalSince($0.createdAt) >= 86_400 }
        let pool = (settled.isEmpty ? available : settled)
            // Stable input order, so the same day always draws the same notes.
            .sorted { $0.id.uuidString < $1.id.uuidString }

        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let seed = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        var rng = SplitMix64(seed: UInt64(seed) &+ 0x6D65_6D6F)
        // Fisher–Yates with the seeded generator.
        var shuffled = pool
        for index in stride(from: shuffled.count - 1, to: 0, by: -1) {
            let other = Int(rng.next() % UInt64(index + 1))
            shuffled.swapAt(index, other)
        }
        return Array(shuffled.prefix(limit))
    }

    /// Every note that belongs to a record — about the record itself or any
    /// song on it — newest first.
    public static func about(album key: Album.Key, in memories: [Memory]) -> [Memory] {
        memories.filter { $0.subject.albumKey == key }.sorted(by: newestFirst)
    }

    /// `12 March 2024`, for the line under a note.
    public var dateDescription: String {
        createdAt.formatted(date: .long, time: .omitted)
    }
}

/// Where memories are kept. A boundary of its own, like `PlayLogStore`: the
/// app keeps them in the library database, previews and tests in memory.
public protocol MemoryStore: Sendable {
    /// Every memory, in no particular order.
    func memories() async throws -> [Memory]
    /// Creates the memory, or replaces the one with the same id.
    func saveMemory(_ memory: Memory) async throws
    func deleteMemory(_ id: Memory.ID) async throws
}

public actor InMemoryMemoryStore: MemoryStore {
    private var stored: [Memory]

    public init(memories: [Memory] = []) { stored = memories }

    public func memories() async throws -> [Memory] { stored }

    public func saveMemory(_ memory: Memory) async throws {
        if let index = stored.firstIndex(where: { $0.id == memory.id }) {
            stored[index] = memory
        } else {
            stored.append(memory)
        }
    }

    public func deleteMemory(_ id: Memory.ID) async throws {
        stored.removeAll { $0.id == id }
    }
}
