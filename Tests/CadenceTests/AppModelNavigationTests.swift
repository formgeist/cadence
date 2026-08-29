import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// The back stack in `AppModel.show(_:)` / `goBack()`. Pure logic over a
/// value type — no window, no store round trip — so these run as fast as the
/// store-level suites. See #44.
@Suite("AppModel navigation")
@MainActor
struct AppModelNavigationTests {

    private func makeModel() -> AppModel {
        AppModel(store: PreviewData.emptyStore())
    }

    @Test("A fresh model is on the library screen with nothing to go back to")
    func startsAtLibrary() {
        let model = makeModel()
        #expect(model.screen == .library)
        #expect(!model.canGoBack)
    }

    @Test("show pushes the current screen so goBack returns to it")
    func showThenBack() {
        let model = makeModel()

        model.show(.artist("Vera Lindqvist"))
        #expect(model.screen == .artist("Vera Lindqvist"))
        #expect(model.canGoBack)

        model.show(.artist("Halvard Ås"))
        model.goBack()
        #expect(model.screen == .artist("Vera Lindqvist"))

        model.goBack()
        #expect(model.screen == .library)
        #expect(!model.canGoBack)
    }

    @Test("Showing the screen already on display does not push a duplicate")
    func showCurrentIsANoOp() {
        let model = makeModel()

        model.show(.artist("Vera Lindqvist"))
        model.show(.artist("Vera Lindqvist"))
        #expect(model.canGoBack)

        model.goBack()
        // One push, so one Back reaches the library — a duplicate would have
        // stranded us on the artist screen.
        #expect(model.screen == .library)
    }

    @Test("goBack on an empty stack holds still rather than trapping")
    func goBackWithEmptyStack() {
        let model = makeModel()
        model.goBack()
        #expect(model.screen == .library)
    }
}
