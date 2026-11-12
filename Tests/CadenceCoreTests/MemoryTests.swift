import Testing
import Foundation
@testable import CadenceCore

private let slowHours = Album.Key(albumArtist: "Vera Lindqvist",
                                  title: "Sound of the Slow Hours", year: 2023)
private let other = Album.Key(albumArtist: "Halvard Ås", title: "Nocturne", year: nil)

private func track(_ title: String, album: Album.Key = slowHours) -> Track {
    Track(url: URL(fileURLWithPath: "/music/\(title).flac"), title: title,
          artist: album.albumArtist, albumTitle: album.title, year: album.year, duration: 200)
}

@Suite("Memories")
struct MemoryTests {

    @Test("Text is trimmed, capped, and nothing is nil")
    func cleaned() {
        #expect(Memory.cleaned("  first night in the flat \n") == "first night in the flat")
        #expect(Memory.cleaned(" \n\t ") == nil)
        let long = String(repeating: "a", count: Memory.maximumLength + 40)
        #expect(Memory.cleaned(long)?.count == Memory.maximumLength)
    }

    @Test("A song's note is identified by its names and its record")
    func trackSubject() {
        let anhedonia = track("Anhedonia")
        let subject = Memory.Subject(track: anhedonia)
        #expect(subject.albumKey == slowHours)
        #expect(subject.trackTitle == "Anhedonia")
        #expect(subject.matches(anhedonia))
        // A fresh `Track` for the same file — a rescan — still matches.
        #expect(subject.matches(track("Anhedonia")))
        // The same title on another record does not.
        #expect(!subject.matches(track("Anhedonia", album: other)))
        #expect(Memory.Subject.album(slowHours).trackTitle == nil)
    }

    @Test("A record's notes include its songs' notes, newest first")
    func aboutAlbum() {
        let now = Date()
        let old = Memory(subject: .album(slowHours), text: "old", createdAt: now - 500)
        let song = Memory(subject: .init(track: track("Undertow")), text: "song",
                          createdAt: now - 100)
        let elsewhere = Memory(subject: .album(other), text: "elsewhere", createdAt: now)
        #expect(Memory.about(album: slowHours, in: [old, elsewhere, song]).map(\.text)
                == ["song", "old"])
    }

    @Test("Home brings back the same notes all day, and at most the limit")
    func resurfacedIsStableForTheDay() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let notes = (0..<10).map {
            Memory(subject: .album(slowHours), text: "\($0)", createdAt: now - Double($0 + 2) * 86_400)
        }
        let morning = Memory.resurfaced(from: notes, now: now, limit: 3)
        let evening = Memory.resurfaced(from: notes.reversed(), now: now + 3_600, limit: 3)
        #expect(morning.count == 3)
        #expect(morning == evening)
    }

    @Test("A note written today waits while older ones exist")
    func freshNotesWait() {
        let now = Date()
        let fresh = Memory(subject: .album(slowHours), text: "fresh", createdAt: now - 60)
        let settled = Memory(subject: .album(other), text: "settled", createdAt: now - 10 * 86_400)
        #expect(Memory.resurfaced(from: [fresh, settled], now: now).map(\.text) == ["settled"])
        // With nothing older, today's note is better than an empty shelf.
        #expect(Memory.resurfaced(from: [fresh], now: now).map(\.text) == ["fresh"])
    }

    @Test("Notes the caller cannot show are left out")
    func unavailableLeftOut() {
        let now = Date()
        let here = Memory(subject: .album(slowHours), text: "here", createdAt: now - 5 * 86_400)
        let gone = Memory(subject: .album(other), text: "gone", createdAt: now - 5 * 86_400)
        let shown = Memory.resurfaced(from: [here, gone], now: now) { $0.subject.albumKey == slowHours }
        #expect(shown.map(\.text) == ["here"])
        #expect(Memory.resurfaced(from: [], now: now).isEmpty)
    }
}

@Suite("Home's daily pick")
struct DailyPickTests {
    private let day: TimeInterval = 86_400
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func albumPick() -> AlbumOfTheDay {
        AlbumOfTheDay(album: Album(key: slowHours, tracks: [track("Anhedonia")]),
                      headline: "Pulled from the shelf", detail: "Not played yet")
    }

    private func note() -> Memory {
        Memory(subject: .album(other), text: "Late shift.", createdAt: base - 30 * day)
    }

    @Test("Nothing to show is nil; one kind alone is always chosen")
    func oneSided() {
        #expect(DailyPick.choose(album: nil, memories: [], now: base) == nil)
        // One instance: each `albumPick()` mints a track with a fresh id.
        let album = albumPick()
        #expect(DailyPick.choose(album: album, memories: [], now: base) == .album(album))
        let memory = note()
        #expect(DailyPick.choose(album: nil, memories: [memory], now: base) == .memory(memory))
    }

    @Test("The pick holds all day, and over a month both kinds come up")
    func stableAndMixed() {
        let album = albumPick()
        let memory = note()
        let morning = DailyPick.choose(album: album, memories: [memory], now: base)
        let evening = DailyPick.choose(album: album, memories: [memory], now: base + 3_600)
        #expect(morning == evening)

        var kinds = Set<String>()
        for offset in 0..<30 {
            switch DailyPick.choose(album: album, memories: [memory], now: base + Double(offset) * day) {
            case .album: kinds.insert("album")
            case .memory: kinds.insert("memory")
            case nil: break
            }
        }
        #expect(kinds == ["album", "memory"])
    }
}
