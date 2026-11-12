import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// A memory store that can be told to fail its writes.
private actor FailingMemoryStore: MemoryStore {
    private let inner: InMemoryMemoryStore
    private let failsWrites: Bool

    init(memories: [Memory] = [], failsWrites: Bool) {
        inner = InMemoryMemoryStore(memories: memories)
        self.failsWrites = failsWrites
    }

    func memories() async throws -> [Memory] { try await inner.memories() }
    func saveMemory(_ memory: Memory) async throws {
        if failsWrites { throw StubStoreError() }
        try await inner.saveMemory(memory)
    }
    func deleteMemory(_ id: Memory.ID) async throws {
        if failsWrites { throw StubStoreError() }
        try await inner.deleteMemory(id)
    }
}

/// Memories as the model keeps them: loaded beside the library, grouped by
/// record, saved and deleted through the store, and only resurfaced on Home
/// when there is a record to open.
@Suite("AppModel memories")
@MainActor
struct AppModelMemoryTests {

    private let anhedonia = stubTrack("Anhedonia")
    private let undertow = stubTrack("Undertow")

    private func makeModel(_ memories: [Memory] = [],
                       store: (any MemoryStore)? = nil) async -> AppModel {
        let model = AppModel(store: StubLibraryStore(tracks: [anhedonia, undertow]),
                             memories: store ?? InMemoryMemoryStore(memories: memories))
        await model.load()
        return model
    }

    @Test("Notes load with the library and are found by record and by song")
    func loads() async {
        let onAlbum = Memory(subject: .album(anhedonia.albumKey), text: "The flat.",
                             createdAt: Date() - 500)
        let onSong = Memory(subject: .init(track: anhedonia), text: "Ingrid's call.",
                            createdAt: Date() - 100)
        let model = await makeModel([onAlbum, onSong])

        #expect(model.memories(aboutAlbum: anhedonia.albumKey).map(\.id) == [onSong.id, onAlbum.id])
        #expect(model.memories(about: anhedonia).map(\.id) == [onSong.id])
        #expect(model.hasMemory(anhedonia))
        #expect(!model.hasMemory(undertow))
    }

    @Test("A new note is saved, listed, and announced")
    func create() async throws {
        let store = InMemoryMemoryStore()
        let model = await makeModel(store: store)

        await model.saveMemory(text: "  First dance.  ", editing: .create(.init(track: undertow)))

        #expect(model.memories(about: undertow).map(\.text) == ["First dance."])
        #expect(try await store.memories().count == 1)
        #expect(model.notice == "Saved a memory for “Undertow”")
    }

    @Test("An empty new note is not saved")
    func emptyCreateDiscarded() async {
        let model = await makeModel()
        await model.saveMemory(text: " \n ", editing: .create(.album(anhedonia.albumKey)))
        #expect(model.memories.isEmpty)
    }

    @Test("Editing changes the text and keeps the note's date")
    func edit() async throws {
        let original = Memory(subject: .album(anhedonia.albumKey), text: "Draft.",
                              createdAt: Date() - 1_000)
        let model = await makeModel([original])

        await model.saveMemory(text: "Final.", editing: .edit(original))

        let saved = try #require(model.memories.first)
        #expect(saved.id == original.id)
        #expect(saved.text == "Final.")
        #expect(saved.createdAt == original.createdAt)
        #expect(saved.updatedAt > original.createdAt)
    }

    @Test("Emptying a note deletes it")
    func emptyEditDeletes() async {
        let original = Memory(subject: .album(anhedonia.albumKey), text: "Draft.")
        let model = await makeModel([original])

        await model.saveMemory(text: "", editing: .edit(original))

        #expect(model.memories.isEmpty)
    }

    @Test("A failed save says so and changes nothing")
    func failure() async {
        let model = await makeModel(store: FailingMemoryStore(failsWrites: true))

        await model.saveMemory(text: "Lost?", editing: .create(.album(anhedonia.albumKey)))

        #expect(model.memories.isEmpty)
        #expect(model.actionError == "Could not save the memory: disk is full")
    }

    @Test("Home only brings back notes whose record is in the library")
    func resurfacedNeedsAnAlbum() async {
        let here = Memory(subject: .album(anhedonia.albumKey), text: "Here.",
                          createdAt: Date() - 10 * 86_400)
        let gone = Memory(subject: .album(Album.Key(albumArtist: "Nobody", title: "Gone",
                                                     year: nil)),
                          text: "Gone.", createdAt: Date() - 10 * 86_400)
        let model = await makeModel([here, gone])

        #expect(model.showableMemories.map(\.text) == ["Here."])
        // The note on the missing record is still kept, just not shown.
        #expect(model.memories.count == 2)
    }

    @Test("A song note finds its track on the record; a record note has none")
    func trackForSubject() async {
        let model = await makeModel()
        #expect(model.track(for: .init(track: anhedonia))?.id == anhedonia.id)
        #expect(model.track(for: .album(anhedonia.albumKey)) == nil)
        #expect(model.track(for: .track(title: "Gone", artist: "Vera Lindqvist",
                                        album: anhedonia.albumKey)) == nil)
    }

    @Test("Playing a song note plays that song in its record's order")
    func playSongNote() async throws {
        let model = await makeModel()
        let playback = PlaybackController(engine: MockPlayerEngine(rate: 1))
        let album = try #require(model.album(for: anhedonia.albumKey))

        model.play(Memory(subject: .init(track: undertow), text: "Lofoten."), on: playback)

        #expect(playback.currentTrack?.id == undertow.id)
        #expect(playback.queue.map(\.id) == album.discs.flatMap(\.tracks).map(\.id))
    }

    @Test("Playing a record note plays the record from the top")
    func playAlbumNote() async throws {
        let model = await makeModel()
        let playback = PlaybackController(engine: MockPlayerEngine(rate: 1))
        let album = try #require(model.album(for: anhedonia.albumKey))

        model.play(Memory(subject: .album(album.key), text: "The flat."), on: playback)

        #expect(playback.currentTrack?.id == album.discs.flatMap(\.tracks).first?.id)
    }

    @Test("A note on a record no longer in the library cannot play")
    func playMissingRecord() async {
        let model = await makeModel()
        let playback = PlaybackController(engine: MockPlayerEngine(rate: 1))
        let gone = Memory(subject: .album(Album.Key(albumArtist: "Nobody", title: "Gone",
                                                     year: nil)), text: "Gone.")

        #expect(!model.canPlay(gone))
        model.play(gone, on: playback)
        #expect(playback.currentTrack == nil)
    }

    @Test("The Memories page filters by tag and by words, and says how many")
    func pageFilter() async {
        let model = await makeModel([
            Memory(subject: .init(track: anhedonia), text: "Live with #Axel", createdAt: Date() - 300),
            Memory(subject: .init(track: undertow), text: "#Bristol, rain", createdAt: Date() - 200),
            Memory(subject: .album(anhedonia.albumKey), text: "#axel's first record",
                   createdAt: Date() - 100),
        ])
        model.tab = .memories
        #expect(model.memoryTags.map(\.name) == ["Axel", "Bristol"])
        #expect(model.filteredMemories.count == 3)
        #expect(model.screenCount == "3 MEMORIES")

        model.memoryTagFilter = Memory.tagKey("Axel")
        #expect(model.filteredMemories.map(\.text) == ["#axel's first record", "Live with #Axel"])
        #expect(model.screenCount == "2 OF 3 MEMORIES")

        model.memoryQuery = "anhedonia"
        #expect(model.filteredMemories.map(\.text) == ["Live with #Axel"])

        model.clearMemoryFilter()
        #expect(model.filteredMemories.count == 3)
        #expect(!model.isFilteringMemories)
    }

    @Test("A picked tag that no note carries any more filters nothing")
    func staleTag() async {
        let model = await makeModel([Memory(subject: .album(anhedonia.albumKey), text: "Rain.")])
        model.memoryTagFilter = Memory.tagKey("Gone")
        #expect(model.activeMemoryTag == nil)
        #expect(model.filteredMemories.count == 1)
    }

    @Test("A song note is headed by its title, a record note by the record")
    func titles() async {
        let model = await makeModel()
        #expect(model.title(of: .init(track: anhedonia)) == "“Anhedonia”")
        #expect(model.title(of: .album(anhedonia.albumKey)) == "Sound of the Slow Hours")
    }
}
