import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// `recordPlayed(_:from:)` and the `recentPlays` resolution behind the Recents
/// grid — an album credited from a bare track start, a playlist credited when
/// the queue was started from one, most-recent-first ordering with de-dupe, and
/// the list dropping entries the library no longer has.
@Suite("AppModel recents")
@MainActor
struct AppModelRecentsTests {

    private func makeModel(playlists: [Playlist] = []) -> AppModel {
        AppModel(store: PreviewData.store(playlists: playlists))
    }

    private func firstTrack(ofAlbum title: String, in model: AppModel) -> Track {
        model.albums.first { $0.title == title }!.discs.first!.tracks.first!
    }

    @Test("A bare track start credits the album it belongs to")
    func trackStartCreditsAlbum() async {
        let model = makeModel()
        await model.load()

        model.recordPlayed(firstTrack(ofAlbum: "Sound of the Slow Hours", in: model))

        #expect(model.recentPlays.count == 1)
        guard case .album(let album) = model.recentPlays.first else {
            Issue.record("expected an album entry")
            return
        }
        #expect(album.title == "Sound of the Slow Hours")
    }

    @Test("A play started from a playlist credits the playlist, not each album")
    func playlistOriginCreditsPlaylist() async {
        let list = Playlist(name: "Late Desk",
                            trackIDs: Array(PreviewData.tracks.prefix(5).map(\.id)),
                            duration: 900)
        let model = makeModel(playlists: [list])
        await model.load()
        let playlistID = model.playlists.first!.id

        // Three tracks from three different albums roll past under the one
        // playlist — the grid should show the playlist once, no albums.
        for track in PreviewData.tracks.prefix(3) {
            model.recordPlayed(track, from: playlistID)
        }

        #expect(model.recentPlays.count == 1)
        guard case .playlist(let playlist) = model.recentPlays.first else {
            Issue.record("expected a playlist entry")
            return
        }
        #expect(playlist.id == playlistID)
    }

    /// The real wiring: `AppContainer` chains `recordPlayed` onto the
    /// controller's `onTrackStarted`, reading `startedFromPlaylist` off the
    /// controller. This drives that path end to end rather than calling
    /// `recordPlayed` by hand.
    @Test("Playing a track through the controller from a playlist credits the playlist")
    func controllerPlaylistPlayCreditsPlaylist() async throws {
        let all = PreviewData.tracks
        let list = Playlist(name: "Late Desk",
                            trackIDs: Array(all.prefix(4).map(\.id)),
                            duration: 800)
        let model = makeModel(playlists: [list])
        await model.load()
        let playlistID = model.playlists.first!.id
        let listTracks = model.tracks(in: model.playlists.first!)

        let engine = MockPlayerEngine(rate: 1)
        let controller = PlaybackController(engine: engine)
        controller.onTrackStarted = { [weak model] track in
            model?.recordPlayed(track, from: controller.startedFromPlaylist)
        }

        // Double-clicking a row deep in the playlist — the reported case.
        controller.play(listTracks[2], in: listTracks, from: playlistID)
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.recentPlays.count == 1)
        guard case .playlist(let playlist) = model.recentPlays.first else {
            Issue.record("expected a playlist entry, got \(model.recentPlays)")
            return
        }
        #expect(playlist.id == playlistID)
    }

    /// The reported bug: add a song to a playlist, then play it from that
    /// playlist. It should credit the playlist, not the song's album.
    @Test("A just-added song played from its playlist credits the playlist")
    func addedThenPlayedFromPlaylistCreditsPlaylist() async throws {
        let model = makeModel(playlists: [
            Playlist(name: "Late Desk", trackIDs: [], duration: 0),
        ])
        await model.load()
        let listID = model.playlists.first!.id

        // A track from an album already in the library, added to the playlist.
        let song = firstTrack(ofAlbum: "Northerly", in: model)
        await model.addTracks([song.id], to: listID)

        let engine = MockPlayerEngine(rate: 1)
        let controller = PlaybackController(engine: engine)
        controller.onTrackStarted = { [weak model] track in
            model?.recordPlayed(track, from: controller.startedFromPlaylist)
        }

        let listTracks = model.tracks(in: model.playlist(id: listID)!)
        #expect(listTracks.map(\.id) == [song.id])
        controller.play(listTracks[0], in: listTracks, from: listID)
        try await Task.sleep(for: .milliseconds(100))

        guard case .playlist = model.recentPlays.first else {
            Issue.record("expected a playlist entry, got \(model.recentPlays)")
            return
        }
    }

    /// The reported repro precisely: the playlist is *already playing*, a song
    /// is added to it, then that new row is double-clicked.
    @Test("Adding a song to a playing playlist and playing it still credits the playlist")
    func addToPlayingPlaylistThenPlayNewRow() async throws {
        let all = PreviewData.tracks
        let seed = Array(all.prefix(3).map(\.id))
        let model = makeModel(playlists: [
            Playlist(name: "Late Desk", trackIDs: seed, duration: 600),
        ])
        await model.load()
        let listID = model.playlists.first!.id

        let engine = MockPlayerEngine(rate: 1)
        let controller = PlaybackController(engine: engine)
        controller.onTrackStarted = { [weak model] track in
            model?.recordPlayed(track, from: controller.startedFromPlaylist)
        }

        // 1. Playlist is already playing.
        controller.play(model.tracks(in: model.playlist(id: listID)!), fromPlaylist: listID)
        try await Task.sleep(for: .milliseconds(60))

        // 2. A song from another album is added to the playlist.
        let added = firstTrack(ofAlbum: "Northerly", in: model)
        await model.addTracks([added.id], to: listID)

        // 3. Double-click that new row.
        let refreshed = model.tracks(in: model.playlist(id: listID)!)
        controller.play(added, in: refreshed, from: listID)
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.recentPlays.first.map { if case .playlist = $0 { true } else { false } } == true,
                "got \(model.recentPlays)")
    }

    @Test("Most-recent first, and replaying moves an entry to the front")
    func orderingAndDedupe() async {
        let model = makeModel()
        await model.load()

        let slowHours = firstTrack(ofAlbum: "Sound of the Slow Hours", in: model)
        let northerly = firstTrack(ofAlbum: "Northerly", in: model)

        model.recordPlayed(slowHours)
        model.recordPlayed(northerly)
        model.recordPlayed(slowHours)

        let titles = model.recentPlays.map { entry -> String in
            guard case .album(let album) = entry else { return "?" }
            return album.title
        }
        #expect(titles == ["Sound of the Slow Hours", "Northerly"])
    }

    @Test("Replaying the whole library leaves one entry per album, capped")
    func cappedAndDeduped() async {
        let model = makeModel()
        await model.load()

        // Every album, twice over — the list must not grow past one entry each
        // (de-dupe) and never past the 30 cap.
        for _ in 0..<2 {
            for album in model.albums {
                guard let track = album.discs.first?.tracks.first else { continue }
                model.recordPlayed(track)
            }
        }

        #expect(model.recentPlays.count == model.albums.count)
        #expect(model.recentPlays.count <= 30)
    }

    @Test("A deleted playlist drops out of the grid")
    func deletedPlaylistFallsOut() async {
        let list = Playlist(name: "Late Desk",
                            trackIDs: Array(PreviewData.tracks.prefix(3).map(\.id)),
                            duration: 300)
        let model = makeModel(playlists: [list])
        await model.load()
        let playlistID = model.playlists.first!.id

        model.recordPlayed(PreviewData.tracks[0], from: playlistID)
        #expect(model.recentPlays.count == 1)

        await model.deletePlaylist(model.playlists.first!)

        #expect(model.recentPlays.isEmpty)
    }
}
