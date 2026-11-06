import Testing
import Foundation
@testable import CadenceLibrary
import CadenceCore

@Suite("SQLite store: play history")
struct PlayLogStoreTests {

    private func withDatabaseURL<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-playlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await body(directory.appendingPathComponent("library.sqlite"))
    }

    private func play(_ title: String, at seconds: TimeInterval, year: Int? = 2001) -> PlayRecord {
        PlayRecord(title: title, artist: "Artist", albumArtist: "Album Artist",
                   albumTitle: "Album", albumYear: year, duration: 200,
                   playedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test("Plays survive a relaunch, oldest first, with every field")
    func roundTrip() async throws {
        try await withDatabaseURL { url in
            let first = try SQLiteLibraryStore(url: url)
            try await first.record(play("Later", at: 2_000))
            try await first.record(play("Earlier", at: 1_000, year: nil))

            let second = try SQLiteLibraryStore(url: url)
            let plays = try await second.allPlays()
            #expect(plays.map(\.title) == ["Earlier", "Later"])
            #expect(plays[0].albumYear == nil)
            #expect(plays[1].albumYear == 2001)
            #expect(plays[1].albumArtist == "Album Artist")
            #expect(plays[1].duration == 200)
            #expect(plays[1].playedAt == Date(timeIntervalSince1970: 2_000))
        }
    }
}
