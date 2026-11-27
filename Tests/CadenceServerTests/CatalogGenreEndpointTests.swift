import Testing
import Foundation
import CadenceCore
import CadenceLibrary
import CadenceServer

private func track(_ title: String, album: String, artist: String = "Vera Lindqvist",
                   year: Int? = 2023, number: Int, genre: String? = nil,
                   label: String? = nil, artwork: String? = nil, added: TimeInterval = 0) -> Track {
    Track(url: URL(fileURLWithPath: "/Volumes/secret-folder/\(album)/\(number) \(title).flac"),
          title: title, artist: artist, albumArtist: artist, albumTitle: album, genre: genre,
          year: year, label: label, trackNumber: number, duration: 200, format: .cd,
          artworkID: artwork, dateAdded: Date(timeIntervalSince1970: 1_700_000_000 + added))
}

private let corpus: [Track] = [
    // Mostly Ambient, with one stray Jazz track: filed under Ambient only.
    track("One", album: "Slow Hours", number: 1, genre: "Ambient", label: "ECM", artwork: "aa11"),
    track("Two", album: "Slow Hours", number: 2, genre: "ambient", label: "ECM", artwork: "aa11"),
    track("Three", album: "Slow Hours", number: 3, genre: "Jazz", label: "ECM", artwork: "aa11"),
    track("Köln", album: "Concert", artist: "Keith Jarrett", year: 1975, number: 1,
          genre: "Jazz", label: "ECM", artwork: "bb22"),
    track("Untagged", album: "Early Works", year: nil, number: 1),
]

private func names(_ items: Any?) -> [String] {
    (items as? [[String: Any]] ?? []).compactMap { ($0["name"] ?? $0["value"]) as? String }
}

@Suite("Genre and catalog endpoints")
struct CatalogGenreEndpointTests {

    @Test("Genres are grouped as the Mac groups them, A–Z, with covers")
    func genres() async throws {
        let server = try await TestLibrary(corpus).server()
        let genres = try #require(await server.get("getGenres").object("genres")["genre"]
            as? [[String: Any]])
        #expect(names(genres) == ["Ambient", "Jazz"])
        #expect(genres[0]["albumCount"] as? Int == 1)
        #expect(genres[0]["songCount"] as? Int == 3)
        #expect(genres[0]["cadenceCoverArt"] as? [String] == ["aa11"])
        #expect(genres[1]["albumCount"] as? Int == 1)
    }

    @Test("A genre's album list agrees with its count")
    func byGenreAgrees() async throws {
        let server = try await TestLibrary(corpus).server()
        func list(_ genre: String) async -> [String] {
            names(await server.get("getAlbumList2", [("type", "byGenre"), ("genre", genre),
                                                     ("size", "50")]).object("albumList2")["album"])
        }
        #expect(await list("ambient") == ["Slow Hours"])
        // The one Jazz track on Slow Hours does not file the album under Jazz.
        #expect(await list("JAZZ") == ["Concert"])
        #expect(await list("Polka") == [])
    }

    @Test("Catalogs list with a summary, a count and covers, and open in their own order")
    func catalogs() async throws {
        let library = try await TestLibrary(corpus)
        let ecm = Catalog(name: "ECM", definition: .init(
            rules: [CatalogRule(field: .label, text: "ECM")], sort: .yearOldest))
        let empty = Catalog(name: "Nothing yet", definition: .init())
        try await library.store.saveCatalog(ecm)
        try await library.store.saveCatalog(empty)
        let server = library.server()

        let list = try #require(await server.get("getCadenceCatalogs")
            .object("cadenceCatalogs")["catalog"] as? [[String: Any]])
        #expect(Set(names(list)) == ["ECM", "Nothing yet"])
        let entry = try #require(list.first { $0["name"] as? String == "ECM" })
        let id = try #require(entry["id"] as? String)
        #expect(id == "ca-" + ecm.id.uuidString.lowercased())
        #expect(entry["summary"] as? String == "Label is ECM")
        #expect(entry["albumCount"] as? Int == 2)
        #expect(entry["coverArt"] as? [String] == ["bb22", "aa11"])
        #expect(entry["album"] == nil)

        let opened = await server.get("getCadenceCatalog", [("id", id)]).object("cadenceCatalog")
        let albums = try #require(opened["album"] as? [[String: Any]])
        #expect(names(albums) == ["Concert", "Slow Hours"])
        // Albums in a catalog are list entries, without their songs.
        #expect(albums.allSatisfy { $0["song"] == nil })
    }

    @Test("A catalog id that is not one is not found")
    func catalogNotFound() async throws {
        let server = try await TestLibrary(corpus).server()
        #expect(await server.get("getCadenceCatalog").errorCode == 10)
        for id in ["ca-" + UUID().uuidString.lowercased(), "pl-" + UUID().uuidString.lowercased(),
                   "ca-" + UUID().uuidString.uppercased(), "nonsense"] {
            #expect(await server.get("getCadenceCatalog", [("id", id)]).errorCode == 70)
        }
    }

    @Test("An empty library has no genres and no catalogs, not an error")
    func empty() async throws {
        let server = try await TestLibrary().server()
        #expect(await server.get("getGenres").isOK)
        #expect(await server.get("getCadenceCatalogs").isOK)
    }

    @Test("Both need a key", arguments: ["getGenres", "getCadenceCatalogs", "getCadenceCatalog"])
    func needsKey(endpoint: String) async throws {
        let server = try await TestLibrary(corpus).server()
        #expect(await server.get(endpoint, [("id", "x")], authenticated: false).errorCode == 44)
    }

    @Test("No answer says where a file is")
    func noPaths() async throws {
        let library = try await TestLibrary(corpus)
        try await library.store.saveCatalog(Catalog(name: "ECM", definition: .init(
            rules: [CatalogRule(field: .label, text: "ECM")])))
        let server = library.server()
        let id = try #require((await server.get("getCadenceCatalogs")
            .object("cadenceCatalogs")["catalog"] as? [[String: Any]])?.first?["id"] as? String)
        for response in [await server.get("getGenres"),
                         await server.get("getCadenceCatalog", [("id", id)])] {
            #expect(!response.text.contains("secret-folder"))
        }
    }
}
