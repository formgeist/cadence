import Testing
import Foundation
@testable import CadenceCore

/// `InMemoryLibraryStore` is what previews, `--snapshot` and `--a11y` run
/// against, so a playlist edit that behaves differently here than in SQLite
/// means every screen is reviewed against a fiction. These mirror the SQLite
/// suite's playlist cases deliberately.
@Suite("In-memory playlist edits")
struct InMemoryPlaylistTests {

    private func makeTrack(_ title: String, seconds: TimeInterval = 100) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(title).flac"),
              title: title,
              artist: "Vera Lindqvist",
              albumTitle: "Sound of the Slow Hours",
              duration: seconds)
    }

    @Test("Tracks append in order, and the duration follows them")
    func addTracks() async throws {
        let tracks = (1...3).map { makeTrack("Track \($0)") }
        let store = InMemoryLibraryStore(tracks: tracks)
        let playlist = try await store.createPlaylist(named: "Late Desk")

        try await store.addTracks([tracks[2].id, tracks[0].id], to: playlist.id)

        let fetched = try #require(try await store.playlists().first)
        #expect(fetched.trackIDs == [tracks[2].id, tracks[0].id])
        // The real store recomputes this with a SUM; here it is kept in step by
        // hand, which is exactly the part that can silently drift.
        #expect(fetched.duration == 200)
    }

    @Test("An id with no track behind it is skipped")
    func addGhostTrack() async throws {
        let track = makeTrack("Slow Hours")
        let store = InMemoryLibraryStore(tracks: [track])
        let playlist = try await store.createPlaylist(named: "Late Desk")

        try await store.addTracks([UUID(), track.id], to: playlist.id)

        #expect(try await store.playlists().first?.trackIDs == [track.id])
    }

    @Test("Removing by offset takes one of two identical entries")
    func removeByOffset() async throws {
        let track = makeTrack("Slow Hours")
        let store = InMemoryLibraryStore(tracks: [track])
        let playlist = try await store.createPlaylist(named: "Late Desk")
        try await store.addTracks([track.id, track.id], to: playlist.id)

        try await store.removeTracks(atOffsets: IndexSet([0]), from: playlist.id)

        #expect(try await store.playlists().first?.trackIDs == [track.id])
        #expect(try await store.playlists().first?.duration == 100)
    }

    @Test("Reordering matches SwiftUI's onMove semantics")
    func moveTracks() async throws {
        let tracks = (1...4).map { makeTrack("Track \($0)") }
        let store = InMemoryLibraryStore(tracks: tracks)
        let playlist = try await store.createPlaylist(named: "Late Desk")
        try await store.addTracks(tracks.map(\.id), to: playlist.id)

        try await store.moveTracks(fromOffsets: IndexSet([0]), toOffset: 3,
                                   in: playlist.id)

        #expect(try await store.playlists().first?.trackIDs
                == [tracks[1].id, tracks[2].id, tracks[0].id, tracks[3].id])
    }

    @Test("Renaming and deleting address the playlist by id, not by name")
    func renameAndDelete() async throws {
        let store = InMemoryLibraryStore(tracks: [])
        let first = try await store.createPlaylist(named: "Untitled")
        let second = try await store.createPlaylist(named: "Untitled")

        try await store.renamePlaylist(second.id, to: "Headphones Only")
        #expect(try await store.playlists().map(\.name) == ["Untitled", "Headphones Only"])

        try await store.deletePlaylist(first.id)
        let remaining = try await store.playlists()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == second.id)
    }

    @Test("An out-of-range offset is ignored rather than trapping")
    func outOfRangeOffset() async throws {
        let track = makeTrack("Slow Hours")
        let store = InMemoryLibraryStore(tracks: [track])
        let playlist = try await store.createPlaylist(named: "Late Desk")
        try await store.addTracks([track.id], to: playlist.id)

        try await store.removeTracks(atOffsets: IndexSet([7]), from: playlist.id)

        #expect(try await store.playlists().first?.trackIDs == [track.id])
    }
}
