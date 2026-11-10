import Testing
import Foundation
@testable import CadenceCore

@Suite("Catalog rules")
struct CatalogTests {

    private func track(_ album: String, artist: String = "Artist", albumArtist: String? = nil,
                       year: Int? = 1975,
                       label: String? = nil, genre: String? = nil,
                       format: AudioFormat = .cd, added: Date = Date(timeIntervalSince1970: 0),
                       art: String? = nil) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(album)/\(UUID().uuidString).flac"),
              title: "T", artist: artist, albumArtist: albumArtist, albumTitle: album, genre: genre, year: year,
              label: label, duration: 60, format: format, artworkID: art, dateAdded: added)
    }

    private func album(_ tracks: Track...) -> Album {
        Album.grouped(from: tracks)[0]
    }

    private func matches(_ rule: CatalogRule, _ album: Album, now: Date = Date()) -> Bool {
        rule.matches(album, now: now)
    }

    @Test("Text rules fold case, whitespace and diacritics")
    func textFolding() {
        let ecm = album(track("A", label: " ECM Records "))
        #expect(matches(CatalogRule(field: .label, op: .is, text: "ecm records"), ecm))
        #expect(matches(CatalogRule(field: .label, op: .contains, text: "ecm"), ecm))
        #expect(!matches(CatalogRule(field: .label, op: .isNot, text: "ECM RECORDS"), ecm))
        #expect(matches(CatalogRule(field: .label, op: .doesNotContain, text: "Blue"), ecm))
        let bjork = album(track("B", artist: "Björk"))
        #expect(matches(CatalogRule(field: .artist, op: .is, text: "bjork"), bjork))
    }

    @Test("Artist rules see track artists on a compilation, not just the album artist")
    func trackArtists() {
        let comp = album(
            track("C", artist: "Miles Davis", albumArtist: "Various Artists"),
            track("C", artist: "Bill Evans", albumArtist: "Various Artists"))
        #expect(matches(CatalogRule(field: .artist, text: "Bill Evans"), comp))
    }

    @Test("Year rules: is, between either way round, before and after")
    func years() {
        let a = album(track("A", year: 1975))
        #expect(matches(CatalogRule(field: .year, op: .is, number: 1975), a))
        #expect(matches(CatalogRule(field: .year, op: .between, number: 1980, upperNumber: 1970), a))
        #expect(!matches(CatalogRule(field: .year, op: .before, number: 1975), a))
        #expect(matches(CatalogRule(field: .year, op: .after, number: 1974), a))
        let undated = album(track("U", year: nil))
        #expect(!matches(CatalogRule(field: .year, op: .after, number: 1000), undated))
    }

    @Test("Decade rules match the whole decade, and an undated record is in none")
    func decades() {
        #expect(matches(CatalogRule(field: .decade, number: 1970), album(track("A", year: 1979))))
        #expect(!matches(CatalogRule(field: .decade, number: 1970), album(track("B", year: 1980))))
        #expect(matches(CatalogRule(field: .decade, op: .isNot, number: 1970),
                        album(track("U", year: nil))))
    }

    @Test("Format: lossless needs every track, hi-res any, codecs by name")
    func formats() {
        let mixed = album(track("M", format: .cd),
                          track("M", format: AudioFormat(codec: .mp3, sampleRate: 44_100)))
        let hires = album(track("H", format: .hiRes))
        typealias F = CatalogRule.FormatChoice
        #expect(!matches(CatalogRule(field: .format, text: F.lossless), mixed))
        #expect(matches(CatalogRule(field: .format, text: F.lossy), mixed))
        #expect(matches(CatalogRule(field: .format, text: F.hiRes), hires))
        #expect(!matches(CatalogRule(field: .format, text: F.hiRes), mixed))
        #expect(matches(CatalogRule(field: .format, text: "mp3"), mixed))
        #expect(matches(CatalogRule(field: .format, op: .isNot, text: "MP3"), hires))
    }

    @Test("Date added counts back from now")
    func dateAdded() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let recent = album(track("R", added: now.addingTimeInterval(-3 * 86_400)))
        let old = album(track("O", added: now.addingTimeInterval(-60 * 86_400)))
        let rule = CatalogRule(field: .dateAdded, number: 30)
        #expect(rule.op == .inLast)
        #expect(matches(rule, recent, now: now))
        #expect(!matches(rule, old, now: now))
        #expect(matches(CatalogRule(field: .dateAdded, op: .notInLast, number: 30), old, now: now))
    }

    @Test("All needs every rule, any needs one; incomplete rules are ignored")
    func matchModes() {
        let ecm70 = album(track("A", year: 1975, label: "ECM"))
        let ecm80 = album(track("B", year: 1985, label: "ECM"))
        let other = album(track("C", year: 1975, label: "Impulse!"))
        let rules = [CatalogRule(field: .label, text: "ECM"),
                     CatalogRule(field: .decade, number: 1970),
                     CatalogRule(field: .genre, text: "  ")]
        let all = Catalog.Definition(match: .all, rules: rules, sort: .title)
        #expect(all.albums(from: [ecm70, ecm80, other]).map(\.title) == ["A"])
        let any = Catalog.Definition(match: .any, rules: rules, sort: .title)
        #expect(any.albums(from: [ecm70, ecm80, other]).map(\.title) == ["A", "B", "C"])
        #expect(all.completeRules.count == 2)
        #expect(all.summary == "Label is ECM and Decade is 1970s")
    }

    @Test("A definition with no complete rules holds nothing")
    func emptyDefinition() {
        let definition = Catalog.Definition(rules: [CatalogRule(field: .label)])
        #expect(definition.albums(from: [album(track("A", label: "ECM"))]).isEmpty)
    }

    @Test("Year sorts put undated records last in both directions")
    func yearSort() {
        let albums = [album(track("Mid", year: 1990)), album(track("None", year: nil)),
                      album(track("Old", year: 1960)), album(track("New", year: 2020))]
        #expect(CatalogSort.yearOldest.sorted(albums).map(\.title) == ["Old", "Mid", "New", "None"])
        #expect(CatalogSort.yearNewest.sorted(albums).map(\.title) == ["New", "Mid", "Old", "None"])
    }

    @Test("Changing a rule's field keeps what still applies and resets the rest")
    func changeField() {
        var rule = CatalogRule(field: .label, op: .contains, text: "ECM")
        rule.change(to: .artist)
        #expect(rule.op == .contains && rule.text == "ECM")
        rule.change(to: .year)
        #expect(rule.op == .is && rule.text.isEmpty)
        rule.number = 1977
        rule.change(to: .decade)
        #expect(rule.number == 1970)
        rule.change(to: .dateAdded)
        #expect(rule.op == .inLast && rule.number == 30)
    }

    @Test("A definition survives JSON")
    func codable() throws {
        let definition = Catalog.Definition(match: .any, rules: [
            CatalogRule(field: .year, op: .between, number: 1965, upperNumber: 1975),
            CatalogRule(field: .format, text: CatalogRule.FormatChoice.hiRes),
        ], sort: .recentlyAdded)
        let data = try JSONEncoder().encode(definition)
        #expect(try JSONDecoder().decode(Catalog.Definition.self, from: data) == definition)
    }
}
