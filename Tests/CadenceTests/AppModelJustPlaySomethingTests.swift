import Testing
import Foundation
import CadenceCore
@testable import Cadence

/// "Just play something" (the title bar's die and ⌘J): a random album, from
/// track 1, never the one already playing while there is another to pick.
@Suite("AppModel just play something")
@MainActor
struct AppModelJustPlaySomethingTests {

    private func twoAlbumModel() async -> AppModel {
        let tracks = [
            stubTrack("A1", album: "First"), stubTrack("A2", album: "First"),
            stubTrack("B1", album: "Second"), stubTrack("B2", album: "Second"),
        ]
        let model = AppModel(store: StubLibraryStore(tracks: tracks))
        await model.load()
        return model
    }

    @Test("Plays an album from its first track and counts the pick")
    func playsFromTheTop() async {
        let model = await twoAlbumModel()
        let playback = PlaybackController(engine: MockPlayerEngine(rate: 1))

        model.justPlaySomething(on: playback)

        let album = try? #require(model.albums.first { $0.key == playback.currentTrack?.albumKey })
        #expect(playback.currentTrack?.id == album?.discs.flatMap(\.tracks).first?.id)
        #expect(model.somethingPlayed == 1)
    }

    @Test("Each pick changes the record when the library has another")
    func avoidsTheAlbumAlreadyPlaying() async {
        let model = await twoAlbumModel()
        let playback = PlaybackController(engine: MockPlayerEngine(rate: 1))

        model.justPlaySomething(on: playback)
        for _ in 0..<10 {
            let before = playback.currentTrack?.albumKey
            model.justPlaySomething(on: playback)
            #expect(playback.currentTrack?.albumKey != before)
        }
    }

    @Test("An empty library plays nothing and does not roll the die")
    func emptyLibraryIsANoOp() async {
        let model = AppModel(store: PreviewData.emptyStore())
        await model.load()
        let playback = PlaybackController(engine: MockPlayerEngine(rate: 1))

        model.justPlaySomething(on: playback)

        #expect(playback.currentTrack == nil)
        #expect(model.somethingPlayed == 0)
    }
}

/// The die's roll animation tumbles a cube whose landing turn must bring the
/// chosen result to the front, or the face it lands on and the face it then
/// rests on disagree.
@Suite("Die cube layout")
struct DieCubeTests {

    @Test("Every start and result gives a real die that lands on the result")
    func landsOnTheResult() {
        for front in 1...6 {
            for result in 1...6 {
                let cube = DieCube(front: front, result: result)
                // +z, -z, +x, -x, +y, -y: opposite faces sum to seven.
                #expect(Set(cube.faces) == Set(1...6))
                #expect(cube.faces[0] + cube.faces[1] == 7)
                #expect(cube.faces[2] + cube.faces[3] == 7)
                #expect(cube.faces[4] + cube.faces[5] == 7)
                #expect(cube.faces[0] == front)

                // A quarter turn end over end brings +y to the front, a half
                // turn brings -z.
                let landed: Int? = switch cube.finalPitch {
                case 0: cube.faces[0]
                case 90: cube.faces[4]
                case 180: cube.faces[1]
                default: nil
                }
                #expect(landed == result, "front \(front), result \(result)")
            }
        }
    }
}
