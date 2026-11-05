import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// Sidebar playlist folders as the model sees them: which playlists sit
/// where, the create/rename/delete funnel, moves, and the collapsed state
/// that has to outlive a relaunch. Not `AppModelFolderTests` — that suite is
/// about music folders on disk.
@Suite("AppModel playlist folders")
@MainActor
struct AppModelPlaylistFolderTests {

    private func playlist(_ name: String, in folder: PlaylistFolder? = nil) -> Playlist {
        Playlist(name: name, trackIDs: [], duration: 0, folderID: folder?.id)
    }

    // MARK: Grouping

    @Test("Playlists split between their folders and the top level")
    func grouping() async {
        let work = PlaylistFolder(name: "Work")
        let filed = playlist("Late Desk", in: work)
        let loose = playlist("Reference Tracks")
        let model = AppModel(store: StubLibraryStore(playlists: [filed, loose], folders: [work]))
        await model.load()

        #expect(model.playlistFolders == [work])
        #expect(model.playlists(in: work.id).map(\.id) == [filed.id])
        #expect(model.playlists(in: nil).map(\.id) == [loose.id])
    }

    @Test("A playlist filed under a folder that is gone shows at the top level")
    func unknownFolderFallsBackToTopLevel() async {
        let stray = playlist("Late Desk", in: PlaylistFolder(name: "Gone"))
        let model = AppModel(store: StubLibraryStore(playlists: [stray]))
        await model.load()

        #expect(model.playlists(in: nil).map(\.id) == [stray.id])
    }

    // MARK: Create, rename, delete

    @Test("Creating a folder adds it under the suggested name when none is given")
    func createWithSuggestedName() async {
        let model = AppModel(store: StubLibraryStore())
        await model.load()
        #expect(model.suggestedFolderName == "New Folder")

        await model.createFolder(named: "  ")
        await model.createFolder(named: "Work")

        #expect(model.playlistFolders.map(\.name) == ["New Folder", "Work"])
        #expect(model.suggestedFolderName == "New Folder 2")
        // A new folder has no screen of its own to open.
        #expect(model.screen == .library)
    }

    @Test("A failed create says which folder, and adds nothing")
    func createFailureIsReported() async {
        let model = AppModel(store: StubLibraryStore(failing: [.createFolder]))
        await model.load()

        await model.createFolder(named: "Work")

        #expect(model.playlistFolders.isEmpty)
        #expect(model.actionError == "Could not create “Work”: disk is full")
    }

    @Test("Renaming trims, and an empty name leaves the folder as it was")
    func rename() async throws {
        let work = PlaylistFolder(name: "Work")
        let model = AppModel(store: StubLibraryStore(folders: [work]))
        await model.load()

        await model.renameFolder(work, to: "  Desk ")
        #expect(model.playlistFolders.map(\.name) == ["Desk"])

        let renamed = try #require(model.playlistFolder(id: work.id))
        await model.renameFolder(renamed, to: "   ")
        #expect(model.playlistFolders.map(\.name) == ["Desk"])
    }

    @Test("Deleting a folder keeps its playlists and puts them at the top level")
    func deleteKeepsPlaylists() async {
        let work = PlaylistFolder(name: "Work")
        let filed = playlist("Late Desk", in: work)
        let model = AppModel(store: StubLibraryStore(playlists: [filed], folders: [work]))
        await model.load()

        await model.deleteFolder(work)

        #expect(model.playlistFolders.isEmpty)
        #expect(model.playlists.map(\.id) == [filed.id])
        #expect(model.playlists(in: nil).map(\.id) == [filed.id])
    }

    @Test("A failed delete leaves the folder and its playlists where they were")
    func deleteFailureIsReported() async {
        let work = PlaylistFolder(name: "Work")
        let filed = playlist("Late Desk", in: work)
        let model = AppModel(store: StubLibraryStore(playlists: [filed], folders: [work],
                                                     failing: [.deleteFolder]))
        await model.load()

        await model.deleteFolder(work)

        #expect(model.playlistFolders == [work])
        #expect(model.playlists(in: work.id).map(\.id) == [filed.id])
        #expect(model.actionError == "Could not delete “Work”: disk is full")
    }

    // MARK: Moving playlists

    @Test("A playlist moves into a folder, across to another, and back out")
    func moveInBetweenAndOut() async {
        let work = PlaylistFolder(name: "Work")
        let archive = PlaylistFolder(name: "Archive")
        let late = playlist("Late Desk")
        let model = AppModel(store: StubLibraryStore(playlists: [late], folders: [work, archive]))
        await model.load()

        await model.movePlaylist(late.id, toFolder: work.id)
        #expect(model.playlists(in: work.id).map(\.id) == [late.id])
        #expect(model.playlists(in: nil).isEmpty)

        await model.movePlaylist(late.id, toFolder: archive.id)
        #expect(model.playlists(in: work.id).isEmpty)
        #expect(model.playlists(in: archive.id).map(\.id) == [late.id])

        await model.movePlaylist(late.id, toFolder: nil)
        #expect(model.playlists(in: archive.id).isEmpty)
        #expect(model.playlists(in: nil).map(\.id) == [late.id])
    }

    @Test("Dropping a playlist where it already is writes nothing")
    func moveToSameFolderIsANoOp() async {
        let work = PlaylistFolder(name: "Work")
        let filed = playlist("Late Desk", in: work)
        // Any write would fail and set `actionError`, so silence proves none
        // was attempted.
        let model = AppModel(store: StubLibraryStore(playlists: [filed], folders: [work],
                                                     failing: [.movePlaylist]))
        await model.load()

        await model.movePlaylist(filed.id, toFolder: work.id)

        #expect(model.actionError == nil)
    }

    @Test("A failed move names the playlist and leaves it where it was")
    func moveFailureIsReported() async {
        let work = PlaylistFolder(name: "Work")
        let late = playlist("Late Desk")
        let model = AppModel(store: StubLibraryStore(playlists: [late], folders: [work],
                                                     failing: [.movePlaylist]))
        await model.load()

        await model.movePlaylist(late.id, toFolder: work.id)

        #expect(model.playlists(in: nil).map(\.id) == [late.id])
        #expect(model.actionError == "Could not move “Late Desk”: disk is full")
    }

    // MARK: Expanding and collapsing

    @Test("Folders start open, and collapsing one survives a relaunch")
    func collapsedStatePersists() async {
        let work = PlaylistFolder(name: "Work")
        let archive = PlaylistFolder(name: "Archive")
        let store = StubLibraryStore(folders: [work, archive])
        let settings = InMemorySettingsStore()

        let model = AppModel(store: store, settings: settings)
        await model.load()
        #expect(model.isExpanded(work))
        model.setExpanded(false, work)
        #expect(!model.isExpanded(work))

        let relaunched = AppModel(store: store, settings: settings)
        await relaunched.load()
        #expect(!relaunched.isExpanded(work))
        #expect(relaunched.isExpanded(archive))

        relaunched.setExpanded(true, work)
        let again = AppModel(store: store, settings: settings)
        #expect(again.isExpanded(work))
    }

    @Test("Moving a playlist into a closed folder opens it, so the playlist stays in view")
    func moveIntoCollapsedFolderExpandsIt() async {
        let work = PlaylistFolder(name: "Work")
        let late = playlist("Late Desk")
        let model = AppModel(store: StubLibraryStore(playlists: [late], folders: [work]))
        await model.load()
        model.setExpanded(false, work)

        await model.movePlaylist(late.id, toFolder: work.id)

        #expect(model.isExpanded(work))
    }
}
