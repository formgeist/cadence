import Testing
@testable import Cadence

/// A headless run must not build the live container: that reads the
/// keychain, and after a rebuild the read waits on a password prompt that
/// nobody sees, so `make shots` hung.
@Suite("Headless launch")
struct HeadlessLaunchTests {

    @Test("Every harness flag is headless", arguments: [
        "--snapshot", "--scan", "--serve", "--share-demo", "--bench", "--a11y",
        "--play", "--audio-check", "--fonts",
    ])
    func harness(flag: String) {
        #expect(AppContainer.isHeadless(["Cadence", flag, "Snapshots"]))
    }

    @Test("A normal launch is not")
    func normal() {
        #expect(!AppContainer.isHeadless(["Cadence"]))
        // The system adds its own arguments to a launch from Finder or Xcode.
        #expect(!AppContainer.isHeadless(["Cadence", "-NSDocumentRevisionsDebugMode", "YES"]))
    }
}
