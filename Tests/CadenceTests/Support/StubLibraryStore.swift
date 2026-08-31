import Foundation
import CadenceCore

/// An error whose `localizedDescription` is predictable, so a test can assert
/// the model folded it into user-facing text rather than swallowing it.
struct StubStoreError: LocalizedError {
    var errorDescription: String? { "disk is full" }
}

/// A `LibraryStore` that reads from an in-memory library but can be told to
/// throw from any one write. `AppModel`'s `edit(_:failing:)` helper and the
/// `createPlaylist` error path both only surface when the store fails
/// mid-edit, which `InMemoryLibraryStore` never does — see #44.
actor StubLibraryStore: LibraryStore {
    enum Operation: Hashable {
        case createPlaylist, addTracks, removeTracks, moveTracks
        case renamePlaylist, deletePlaylist, remove
    }

    private let inner: InMemoryLibraryStore
    private var failing: Set<Operation>

    /// Every track id passed to `remove(trackIDs:)` that got past the failure
    /// guard. `InMemoryLibraryStore.remove` is a no-op, so a caller that wants
    /// to check what a removal actually asked for reads this.
    private(set) var removedTrackIDs: [Track.ID] = []

    init(tracks: [Track] = [], playlists: [Playlist] = [], failing: Set<Operation> = []) {
        self.inner = InMemoryLibraryStore(tracks: tracks, playlists: playlists)
        self.failing = failing
    }

    func setFailing(_ operations: Set<Operation>) { failing = operations }

    private func guardAgainst(_ operation: Operation) throws {
        if failing.contains(operation) { throw StubStoreError() }
    }

    func allTracks() async throws -> [Track] { try await inner.allTracks() }
    func albums() async throws -> [Album] { try await inner.albums() }
    func album(for key: Album.Key) async throws -> Album? { try await inner.album(for: key) }
    func artists() async throws -> [Artist] { try await inner.artists() }
    func albums(byArtist name: String) async throws -> [Album] {
        try await inner.albums(byArtist: name)
    }
    func playlists() async throws -> [Playlist] { try await inner.playlists() }
    func tracks(matching query: String) async throws -> [Track] {
        try await inner.tracks(matching: query)
    }
    func librarySize() async throws -> Int64 { try await inner.librarySize() }

    func customArtistImages() async throws -> [String: Artwork.ID] {
        try await inner.customArtistImages()
    }

    func setCustomArtistImage(_ id: Artwork.ID?, forArtist name: String) async throws {
        try await inner.setCustomArtistImage(id, forArtist: name)
    }

    @discardableResult
    func createPlaylist(named name: String) async throws -> Playlist {
        try guardAgainst(.createPlaylist)
        return try await inner.createPlaylist(named: name)
    }

    func addTracks(_ trackIDs: [Track.ID], to playlistID: Playlist.ID) async throws {
        try guardAgainst(.addTracks)
        try await inner.addTracks(trackIDs, to: playlistID)
    }

    func removeTracks(atOffsets offsets: IndexSet, from playlistID: Playlist.ID) async throws {
        try guardAgainst(.removeTracks)
        try await inner.removeTracks(atOffsets: offsets, from: playlistID)
    }

    func moveTracks(
        fromOffsets source: IndexSet, toOffset destination: Int, in playlistID: Playlist.ID
    ) async throws {
        try guardAgainst(.moveTracks)
        try await inner.moveTracks(fromOffsets: source, toOffset: destination, in: playlistID)
    }

    func renamePlaylist(_ id: Playlist.ID, to name: String) async throws {
        try guardAgainst(.renamePlaylist)
        try await inner.renamePlaylist(id, to: name)
    }

    func deletePlaylist(_ id: Playlist.ID) async throws {
        try guardAgainst(.deletePlaylist)
        try await inner.deletePlaylist(id)
    }

    func upsert(_ tracks: [Track]) async throws { try await inner.upsert(tracks) }

    func remove(trackIDs: [Track.ID]) async throws {
        try guardAgainst(.remove)
        removedTrackIDs.append(contentsOf: trackIDs)
        try await inner.remove(trackIDs: trackIDs)
    }
}

/// A bare track with a distinct title; everything else is filler. Enough for
/// the model's id-mapping and name logic, which never look past those fields.
func stubTrack(_ title: String, artist: String = "Vera Lindqvist",
               album: String = "Sound of the Slow Hours", year: Int? = nil,
               seconds: TimeInterval = 100) -> Track {
    Track(url: URL(fileURLWithPath: "/music/\(title).flac"),
          title: title, artist: artist, albumTitle: album, year: year, duration: seconds)
}
