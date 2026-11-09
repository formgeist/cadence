import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// A user-set artist image overrides the first-album-cover default, and can be
/// taken back off again. The bytes go through the same `ArtworkStore` cover art
/// uses; the override itself is a row keyed by artist name.
@Suite("AppModel artist image")
@MainActor
struct AppModelArtistImageTests {

    /// The smallest valid PNG — one transparent pixel. Enough for ImageIO to
    /// name a type and decode a frame, which is all `setArtistImage` checks.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private func artistTrack(artwork: Artwork.ID?) -> Track {
        var track = stubTrack("Morning Static", artist: "Vera Lindqvist")
        track.artworkID = artwork
        return track
    }

    private func tempFile(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-artist-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    @Test("A stored override wins over the album-cover default")
    func overrideWins() async throws {
        let store = StubLibraryStore(tracks: [artistTrack(artwork: "album-cover")])
        try await store.setCustomArtistImage("chosen", forArtist: "Vera Lindqvist")

        let model = AppModel(store: store)
        await model.load()

        #expect(model.artworkID(forArtist: "Vera Lindqvist") == "chosen")
        #expect(model.hasCustomImage(forArtist: "Vera Lindqvist"))
    }

    @Test("Removing the override falls back to the album cover")
    func removalFallsBack() async throws {
        let store = StubLibraryStore(tracks: [artistTrack(artwork: "album-cover")])
        try await store.setCustomArtistImage("chosen", forArtist: "Vera Lindqvist")

        let model = AppModel(store: store)
        await model.load()
        await model.removeArtistImage(forArtist: "Vera Lindqvist")

        #expect(model.artworkID(forArtist: "Vera Lindqvist") == "album-cover")
        #expect(!model.hasCustomImage(forArtist: "Vera Lindqvist"))
    }

    @Test("Choosing an image file stores it and points the artist at it")
    func setFromImageFile() async throws {
        let store = StubLibraryStore(tracks: [artistTrack(artwork: "album-cover")])
        let model = AppModel(store: store, artwork: InMemoryArtworkStore())
        await model.load()

        let file = try tempFile(Self.onePixelPNG, ext: "png")
        defer { try? FileManager.default.removeItem(at: file) }
        await model.setArtistImage(fromFile: file, forArtist: "Vera Lindqvist")

        #expect(model.hasCustomImage(forArtist: "Vera Lindqvist"))
        #expect(model.artworkID(forArtist: "Vera Lindqvist") != "album-cover")
        #expect(model.notice != nil)
        #expect(model.actionError == nil)
    }

    @Test("Setting an image nudges the artwork loader to drop any stale miss")
    func setFromImageFileRefreshesLoader() async throws {
        let store = StubLibraryStore(tracks: [artistTrack(artwork: "album-cover")])
        let model = AppModel(store: store, artwork: InMemoryArtworkStore())
        await model.load()

        // The loader records a permanent miss for an id it once failed to load;
        // the id lands in the library the instant its bytes are written, so a
        // redraw that raced the write leaves the header stuck on the placeholder
        // until relaunch unless the model clears that entry afterwards — #110.
        var refreshed: [Artwork.ID] = []
        model.refreshArtwork = { refreshed.append($0) }

        let file = try tempFile(Self.onePixelPNG, ext: "png")
        defer { try? FileManager.default.removeItem(at: file) }
        await model.setArtistImage(fromFile: file, forArtist: "Vera Lindqvist")

        #expect(refreshed.count == 1)
        #expect(refreshed.first == model.artworkID(forArtist: "Vera Lindqvist"))
    }

    @Test("A file that isn't an image is refused with a banner, not stored")
    func rejectsNonImage() async throws {
        let store = StubLibraryStore(tracks: [artistTrack(artwork: "album-cover")])
        let model = AppModel(store: store, artwork: InMemoryArtworkStore())
        await model.load()

        let file = try tempFile(Data("this is not an image".utf8), ext: "png")
        defer { try? FileManager.default.removeItem(at: file) }
        await model.setArtistImage(fromFile: file, forArtist: "Vera Lindqvist")

        #expect(!model.hasCustomImage(forArtist: "Vera Lindqvist"))
        #expect(model.artworkID(forArtist: "Vera Lindqvist") == "album-cover")
        #expect(model.actionError != nil)
    }

    @Test("Editing is unavailable when there is no artwork store to write to")
    func editingGatedOnArtworkStore() {
        #expect(!AppModel(store: StubLibraryStore()).canEditArtistImage)
        #expect(AppModel(store: StubLibraryStore(), artwork: InMemoryArtworkStore())
            .canEditArtistImage)
    }
}

/// A playlist's own cover replaces the tiled album covers, and can be taken
/// back off. Same artwork store and validation as the artist images.
@Suite("AppModel playlist cover")
@MainActor
struct AppModelPlaylistCoverTests {

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private func tracks() -> [Track] {
        (1...5).map { n in
            var track = stubTrack("T\(n)", artist: "Artist", album: "Album \(n)")
            track.artworkID = "cover\(n)"
            return track
        }
    }

    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-playlist-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    private func loadedModel(artwork: (any ArtworkStore)? = InMemoryArtworkStore()) async
        -> (AppModel, Playlist)
    {
        let all = tracks()
        let playlist = Playlist(name: "Mix", trackIDs: all.map(\.id), duration: 500)
        let model = AppModel(store: StubLibraryStore(tracks: all, playlists: [playlist]),
                             artwork: artwork)
        await model.load()
        return (model, playlist)
    }

    @Test("Without a cover of its own, a playlist tiles its first four album covers")
    func defaultsToTiles() async {
        let (model, playlist) = await loadedModel()
        #expect(model.coverIDs(forPlaylist: playlist)
                == ["cover1", "cover2", "cover3", "cover4"])
    }

    @Test("Choosing an image file replaces the tiles with that one cover")
    func chosenCoverReplacesTiles() async throws {
        let (model, playlist) = await loadedModel()
        let file = try tempFile(Self.onePixelPNG)
        defer { try? FileManager.default.removeItem(at: file) }

        await model.setPlaylistImage(fromFile: file, for: playlist)

        let updated = try #require(model.playlist(id: playlist.id))
        let chosen = try #require(updated.artworkID)
        #expect(model.coverIDs(forPlaylist: updated) == [chosen])
        #expect(model.notice != nil)
        #expect(model.actionError == nil)
    }

    @Test("Removing the cover goes back to the tiles")
    func removalRestoresTiles() async throws {
        let (model, playlist) = await loadedModel()
        let file = try tempFile(Self.onePixelPNG)
        defer { try? FileManager.default.removeItem(at: file) }
        await model.setPlaylistImage(fromFile: file, for: playlist)

        let withCover = try #require(model.playlist(id: playlist.id))
        await model.removePlaylistImage(for: withCover)

        let reset = try #require(model.playlist(id: playlist.id))
        #expect(reset.artworkID == nil)
        #expect(model.coverIDs(forPlaylist: reset).count == 4)
    }

    @Test("A file that isn't an image is refused and the playlist is left alone")
    func rejectsNonImage() async throws {
        let (model, playlist) = await loadedModel()
        let file = try tempFile(Data("not an image".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        await model.setPlaylistImage(fromFile: file, for: playlist)

        #expect(model.playlist(id: playlist.id)?.artworkID == nil)
        #expect(model.actionError != nil)
    }

    @Test("A failed save surfaces a banner instead of pretending it worked")
    func failedSaveReports() async throws {
        let all = tracks()
        let playlist = Playlist(name: "Mix", trackIDs: all.map(\.id), duration: 500)
        let model = AppModel(
            store: StubLibraryStore(tracks: all, playlists: [playlist],
                                    failing: [.setPlaylistImage]),
            artwork: InMemoryArtworkStore())
        await model.load()
        let file = try tempFile(Self.onePixelPNG)
        defer { try? FileManager.default.removeItem(at: file) }

        await model.setPlaylistImage(fromFile: file, for: playlist)

        #expect(model.actionError != nil)
        #expect(model.notice == nil)
        #expect(model.playlist(id: playlist.id)?.artworkID == nil)
    }

    @Test("Editing is unavailable without an artwork store")
    func gatedOnArtworkStore() async {
        let (model, _) = await loadedModel(artwork: nil)
        #expect(!model.canEditPlaylistImage)
    }
}
