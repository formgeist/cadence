import Foundation
import CadenceCore

/// Launch with `--mock-history` to see Home with a believable listening
/// history over your real library. The plays are made up from the library's own
/// tracks, held in memory, and never written anywhere — quit and they are gone.
///
///     swift run Cadence --mock-history
final class MockPlayLogStore: PlayLogStore, @unchecked Sendable {
    static var isRequested: Bool { CommandLine.arguments.contains("--mock-history") }

    private let library: any LibraryStore
    private let lock = NSLock()
    private var extra: [PlayRecord] = []

    init(library: any LibraryStore) { self.library = library }

    func record(_ play: PlayRecord) async throws {
        lock.withLock { extra.append(play) }
    }

    func allPlays() async throws -> [PlayRecord] {
        let tracks = try await library.allTracks()
        let made = Self.history(from: tracks, now: Date())
        let added = lock.withLock { extra }
        return (made + added).sorted { $0.playedAt < $1.playedAt }
    }

    /// Sixty days of listening that leans on a handful of artists, with a long
    /// tail of one-offs. Seeded, so every launch shows the same history.
    static func history(from tracks: [Track], now: Date) -> [PlayRecord] {
        guard !tracks.isEmpty else { return [] }
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }

        let byArtist = Dictionary(grouping: tracks, by: \.artist)
        let artists = byArtist.keys.sorted()
        // Shuffle deterministically, then weight the front of the list.
        var order = artists
        for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, next(i + 1)) }

        return (0..<420).map { _ in
            // Squaring skews picks toward the first few artists.
            let r = next(1_000)
            let index = min(order.count - 1, r * r * order.count / 1_000_000)
            let group = byArtist[order[index]]!
            let track = group[next(group.count)]
            let minutesAgo = next(60 * 24 * 60)
            return PlayRecord(track: track, playedAt: now.addingTimeInterval(-Double(minutesAgo) * 60))
        }
    }
}
