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
