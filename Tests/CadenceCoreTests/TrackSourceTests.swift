import Testing
import Foundation
import CadenceCore

@Suite("Track sources")
struct TrackSourceTests {

    @Test("A local track resolves to the file it already is")
    func localFile() async throws {
        let file = URL(fileURLWithPath: "/music/Sound of the Slow Hours/02 Slow Hours.flac")
        #expect(try await LocalTrackSource().fileURL(for: file) == file)
    }

    @Test("A local source refuses a track that lives somewhere else")
    func refusesRemote() async {
        let remote = URL(string: "https://mac.local:4533/rest/stream?id=abc")!
        await #expect(throws: PlaybackError.self) {
            try await LocalTrackSource().fileURL(for: remote)
        }
    }
}
