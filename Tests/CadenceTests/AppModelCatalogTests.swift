import Testing
import Foundation
import CadenceCore
@testable import Cadence

@Suite("AppModel catalogs")
@MainActor
struct AppModelCatalogTests {

    private func track(_ album: String, artist: String, year: Int, label: String?) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(album).flac"), title: "T", artist: artist,
              albumTitle: album, year: year, label: label, duration: 100)
    }

    private func makeModel() async -> AppModel {
        let store = InMemoryLibraryStore(tracks: [
            track("Köln Concert", artist: "Keith Jarrett", year: 1975, label: "ECM"),
            track("Bright Size Life", artist: "Pat Metheny", year: 1976, label: "ecm"),
            track("Still Life", artist: "Pat Metheny", year: 1987, label: "Geffen"),
            track("Untagged", artist: "Someone", year: 1977, label: nil),
        ])
        let model = AppModel(store: store)
        await model.load()
        return model
    }

    private var ecm70s: Catalog.Definition {
        .init(match: .all, rules: [CatalogRule(field: .label, text: "ECM"),
                                   CatalogRule(field: .decade, number: 1970)],
              sort: .yearNewest)
    }

    @Test("Creating a catalog stores it, works out its albums, and opens it")
    func create() async {
        let model = await makeModel()
        #expect(model.previewAlbums(for: ecm70s).count == 2)

        await model.saveCatalog(name: "  ECM 70s ", definition: ecm70s, editing: .create)

        let catalog = try! #require(model.catalogs.first)
        #expect(catalog.name == "ECM 70s")
        #expect(model.albums(inCatalog: catalog.id).map(\.title) == ["Bright Size Life", "Köln Concert"])
        #expect(model.screen == .catalog(catalog.id))
        // Survives a reload, from the store.
        await model.load()
        #expect(model.albums(inCatalog: catalog.id).count == 2)
    }

    @Test("Incomplete rules are dropped on save")
    func dropsIncomplete() async {
        let model = await makeModel()
        var definition = ecm70s
        definition.rules.append(CatalogRule(field: .genre))
        await model.saveCatalog(name: "X", definition: definition, editing: .create)
        #expect(model.catalogs.first?.definition.rules.count == 2)
    }

    @Test("Editing, sorting, renaming and deleting")
    func editLifecycle() async {
        let model = await makeModel()
        await model.saveCatalog(name: "ECM", definition: ecm70s, editing: .create)
        var catalog = model.catalogs[0]

        var widened = catalog.definition
        widened.rules.removeLast()
        await model.saveCatalog(name: "", definition: widened, editing: .edit(catalog))
        catalog = model.catalogs[0]
        #expect(catalog.name == "ECM")
        #expect(model.albums(inCatalog: catalog.id).count == 2)

        await model.setSort(.yearOldest, forCatalog: catalog)
        #expect(model.albums(inCatalog: catalog.id).first?.title == "Köln Concert")

        await model.renameCatalog(catalog, to: "Edition of Contemporary Music")
        #expect(model.catalogs[0].name == "Edition of Contemporary Music")

        await model.deleteCatalog(model.catalogs[0])
        #expect(model.catalogs.isEmpty)
        #expect(model.screen == .library)
        #expect(model.tab == .catalogs)
    }

    @Test("Label suggestions fold spellings, keeping the commonest")
    func suggestions() async {
        let model = await makeModel()
        let labels = model.catalogValues(for: .label)
        #expect(labels.count == 2)
        #expect(labels.contains("Geffen"))
        #expect(model.catalogValues(for: .decade) == ["1970", "1980"])
    }
}

@Suite("AppModel catalog search")
@MainActor
struct AppModelCatalogSearchTests {
    @Test("Catalogs match on name, prefix first, and count toward navigation")
    func catalogsAreSearchable() async throws {
        let track = stubTrack("Nightfall", artist: "Vera Lindqvist", album: "After Hours", year: 1975)
        let decade = Catalog.Definition(rules: [CatalogRule(field: .decade, number: 1970)])
        let store = InMemoryLibraryStore(tracks: [track], catalogs: [
            Catalog(name: "Seventies Hours", definition: decade),
            Catalog(name: "Hours of ECM", definition: decade),
            Catalog(name: "Workout", definition: decade),
        ])
        let model = AppModel(store: store)
        await model.load()

        model.searchText = "hours"
        for _ in 0..<50 where model.searchResults.catalogs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.searchResults.catalogs.map(\.name) == ["Hours of ECM", "Seventies Hours"])
        let others = (model.searchResults.topHit != nil ? 1 : 0)
            + model.searchResults.artists.count + model.searchResults.albums.count
            + model.searchResults.playlists.count + model.searchResults.tracks.count
        #expect(model.searchNavigableCount == others + 2)
    }
}
