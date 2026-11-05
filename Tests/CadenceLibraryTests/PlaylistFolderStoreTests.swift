import Testing
import Foundation
import GRDB
@testable import CadenceLibrary
import CadenceCore

/// A fresh temporary directory, removed when the test finishes. The URL is
/// handed over rather than an open store so a test can open the same file
/// twice — which is what a relaunch is.
private func withDatabaseURL<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cadence-folders-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try await body(directory.appendingPathComponent("library.sqlite"))
}

@Suite("SQLite store: playlist folders")
struct PlaylistFolderStoreTests {

    @Test("Folders come back named and in the order they were made")
    func createInOrder() async throws {
        try await withDatabaseURL { url in
            let store = try SQLiteLibraryStore(url: url)
            let first = try await store.createPlaylistFolder(named: "Work")
            let second = try await store.createPlaylistFolder(named: "Archive")

            let folders = try await store.playlistFolders()
            #expect(folders.map(\.id) == [first.id, second.id])
            #expect(folders.map(\.name) == ["Work", "Archive"])
        }
    }

    @Test("A new playlist starts at the top level")
    func newPlaylistIsLoose() async throws {
        try await withDatabaseURL { url in
            let store = try SQLiteLibraryStore(url: url)
            try await store.createPlaylist(named: "Late Desk")
            #expect(try await store.playlists().first?.folderID == nil)
        }
    }

    @Test("A playlist moves into a folder, between folders, and back out")
    func moveInAndOut() async throws {
        try await withDatabaseURL { url in
            let store = try SQLiteLibraryStore(url: url)
            let work = try await store.createPlaylistFolder(named: "Work")
            let archive = try await store.createPlaylistFolder(named: "Archive")
            let playlist = try await store.createPlaylist(named: "Late Desk")

            try await store.movePlaylist(playlist.id, toFolder: work.id)
            #expect(try await store.playlists().first?.folderID == work.id)

            try await store.movePlaylist(playlist.id, toFolder: archive.id)
            #expect(try await store.playlists().first?.folderID == archive.id)

            try await store.movePlaylist(playlist.id, toFolder: nil)
            #expect(try await store.playlists().first?.folderID == nil)
        }
    }

    @Test("Moving into a folder that does not exist is refused, not orphaned")
    func moveToMissingFolderThrows() async throws {
        try await withDatabaseURL { url in
            let store = try SQLiteLibraryStore(url: url)
            let playlist = try await store.createPlaylist(named: "Late Desk")

            await #expect(throws: (any Error).self) {
                try await store.movePlaylist(playlist.id, toFolder: UUID())
            }
            #expect(try await store.playlists().first?.folderID == nil)
        }
    }

    @Test("Renaming a folder changes its name and nothing else")
    func rename() async throws {
        try await withDatabaseURL { url in
            let store = try SQLiteLibraryStore(url: url)
            let folder = try await store.createPlaylistFolder(named: "Work")
            let playlist = try await store.createPlaylist(named: "Late Desk")
            try await store.movePlaylist(playlist.id, toFolder: folder.id)

            try await store.renamePlaylistFolder(folder.id, to: "Desk")

            #expect(try await store.playlistFolders().map(\.name) == ["Desk"])
            #expect(try await store.playlists().first?.folderID == folder.id)
        }
    }

    @Test("Deleting a folder keeps its playlists, tracks and all, at the top level")
    func deleteKeepsPlaylists() async throws {
        try await withDatabaseURL { url in
            let store = try SQLiteLibraryStore(url: url)
            let track = Track(url: URL(fileURLWithPath: "/music/Slow Hours.flac"),
                              title: "Slow Hours", artist: "Vera Lindqvist",
                              albumTitle: "Sound of the Slow Hours", duration: 200)
            try await store.upsert([track])
            let folder = try await store.createPlaylistFolder(named: "Work")
            let kept = try await store.createPlaylist(named: "Late Desk")
            try await store.addTracks([track.id], to: kept.id)
            try await store.movePlaylist(kept.id, toFolder: folder.id)

            try await store.deletePlaylistFolder(folder.id)

            #expect(try await store.playlistFolders().isEmpty)
            let playlists = try await store.playlists()
            #expect(playlists.map(\.id) == [kept.id])
            #expect(playlists.first?.folderID == nil)
            #expect(playlists.first?.trackIDs == [track.id])
        }
    }

    @Test("Folders and what is filed in them survive reopening the database")
    func survivesRelaunch() async throws {
        try await withDatabaseURL { url in
            let folder: PlaylistFolder
            let filed: Playlist
            let loose: Playlist
            do {
                let store = try SQLiteLibraryStore(url: url)
                folder = try await store.createPlaylistFolder(named: "Work")
                filed = try await store.createPlaylist(named: "Late Desk")
                loose = try await store.createPlaylist(named: "Reference Tracks")
                try await store.movePlaylist(filed.id, toFolder: folder.id)
            }

            let reopened = try SQLiteLibraryStore(url: url)
            #expect(try await reopened.playlistFolders() == [folder])
            let byID = Dictionary(uniqueKeysWithValues:
                try await reopened.playlists().map { ($0.id, $0.folderID) })
            #expect(byID[filed.id] == .some(folder.id))
            #expect(byID[loose.id] == .some(nil))
        }
    }

    @Test("A library from before folders migrates with every playlist at the top level")
    func migratesExistingLibrary() async throws {
        try await withDatabaseURL { url in
            let playlistID = UUID()
            // The schema as the last release left it: everything up to, and
            // not including, the folders migration.
            do {
                let queue = try DatabaseQueue(path: url.path,
                                              configuration: Migrations.configuration())
                try Migrations.migrator.migrate(queue, upTo: "v5-track-credits")
                try await queue.write { db in
                    try db.execute(
                        sql: "INSERT INTO playlist (id, name, position) VALUES (?, ?, 0)",
                        arguments: [playlistID.uuidString, "Late Desk"])
                }
            }

            let store = try SQLiteLibraryStore(url: url)
            let playlists = try await store.playlists()
            #expect(playlists.map(\.id) == [playlistID])
            #expect(playlists.first?.folderID == nil)
            #expect(try await store.playlistFolders().isEmpty)

            // And the new column is usable straight away.
            let folder = try await store.createPlaylistFolder(named: "Work")
            try await store.movePlaylist(playlistID, toFolder: folder.id)
            #expect(try await store.playlists().first?.folderID == folder.id)
        }
    }
}
