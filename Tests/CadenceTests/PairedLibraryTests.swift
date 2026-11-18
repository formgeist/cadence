import Testing
import Foundation
import CadenceCore
@testable import Cadence

@Suite("Paired library: settings and links")
@MainActor
struct PairedLibraryTests {

    @Test("The queue and recents are the library's own; volume and scrobbling are shared")
    func settingsSplit() {
        let shared = InMemorySettingsStore()
        let library = InMemorySettingsStore()
        let store = PerLibrarySettingsStore(shared: shared, library: library)

        store.set("[\"a\"]", forKey: .queueTrackIDs)
        store.set(true, forKey: .librarySharingEnabled)
        store.set(0.4, forKey: .volume)
        store.set(true, forKey: .scrobblingEnabled)

        #expect(library.string(forKey: .queueTrackIDs) == "[\"a\"]")
        #expect(shared.string(forKey: .queueTrackIDs) == nil)
        #expect(library.bool(forKey: .librarySharingEnabled) == true)
        #expect(shared.bool(forKey: .librarySharingEnabled) == nil)
        #expect(shared.double(forKey: .volume) == 0.4)
        #expect(shared.bool(forKey: .scrobblingEnabled) == true)
        #expect(library.double(forKey: .volume) == nil)
    }

    @Test("A copied link, with stray whitespace, reads as a pairing")
    func link() throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let payload = PairingPayload(host: "studio-mac.local", port: 4533, fingerprint: fingerprint,
                                     token: String(repeating: "t", count: 43), name: "Studio Mac")
        let text = "  \(try #require(payload.url).absoluteString)\n"
        #expect(try LibrarySourceController.payload(from: text) == payload)
    }

    @Test("Anything else is refused with a sentence that says where to find a link")
    func notALink() {
        #expect(throws: LibrarySourceController.LinkError.notALink) {
            try LibrarySourceController.payload(from: "https://example.com")
        }
        #expect(throws: LibrarySourceController.LinkError.notALink) {
            try LibrarySourceController.payload(from: "cadence://pair?v=1")
        }
    }

    @Test("Another Mac's library hides edits and its size")
    func readOnlyModel() async {
        let model = AppModel(store: PreviewData.store())
        #expect(model.canEditLibrary)
        model.pairedMacName = "Studio Mac"
        #expect(!model.canEditLibrary)
        await model.load()
        #expect(!model.librarySummary.contains("B"))
    }

    @Test("Another Mac's library has no Memories tab, and a session left there opens on Home")
    func noMemories() {
        let settings = InMemorySettingsStore()
        settings.set(AppModel.Tab.memories.rawValue, forKey: .tab)
        let model = AppModel(store: PreviewData.store(), settings: settings)
        #expect(model.tab == .memories)
        #expect(model.visibleTabs.contains(.memories))

        model.pairedMacName = "Studio Mac"
        #expect(model.tab == .home)
        #expect(!model.visibleTabs.contains(.memories))

        model.showMemories(taggedWith: "summer")
        #expect(model.tab == .home)
        #expect(PlaylistMenu.memoryItems(.album(PreviewData.tracks[0].albumKey), model: model).isEmpty)
    }
}
