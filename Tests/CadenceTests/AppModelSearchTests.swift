import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// `searchResults` ranking — that a title starting with the query outranks one
/// that merely contains it, and that the top hit is not repeated in the album
/// list under it. The store answers with its own matching; this is the model's
/// arrangement on top. See #44.
@Suite("AppModel search results")
@MainActor
struct AppModelSearchTests {

    /// `searchText`'s `didSet` debounces for 150ms and then runs the query on a
    /// detached task. Spin until it settles rather than sleeping a fixed span.
    private func runSearch(_ model: AppModel, for query: String) async throws {
        model.searchText = query
        let deadline = ContinuousClock().now + .seconds(2)
        while model.isSearchPending, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isSearchPending)
    }

    private func model() -> AppModel {
        // "After Hours" comes first, so it leads the raw match order — the
        // ranking has to actively promote the prefix hit over it.
        let afterHours = (1...2).map {
            stubTrack("Nightfall \($0)", artist: "Vera Lindqvist", album: "After Hours")
        }
        let hoursOfStatic = (1...2).map {
            stubTrack("Signal \($0)", artist: "Nils Berg", album: "Hours of Static")
        }
        return AppModel(store: StubLibraryStore(tracks: afterHours + hoursOfStatic))
    }

    @Test("A title that starts with the query beats one that only contains it")
    func prefixMatchIsTopHit() async throws {
        let model = model()
        await model.load()

        try await runSearch(model, for: "hours")

        #expect(model.searchResults.topHit?.title == "Hours of Static")
    }

    @Test("The top hit is not listed again in the albums below it")
    func topHitIsExcludedFromAlbums() async throws {
        let model = model()
        await model.load()

        try await runSearch(model, for: "hours")

        let below = model.searchResults.albums.map(\.title)
        #expect(below == ["After Hours"])
        #expect(!below.contains("Hours of Static"))
    }

    @Test("Clearing the query empties the results")
    func clearingQueryResetsResults() async throws {
        let model = model()
        await model.load()
        try await runSearch(model, for: "hours")
        #expect(!model.searchResults.isEmpty)

        model.searchText = ""
        #expect(model.searchResults.isEmpty)
    }
}
