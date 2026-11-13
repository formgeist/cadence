import Testing
import Foundation
import CadenceCore
import CadenceLibrary
import CadenceServer

private func track(
    _ title: String, artist: String, albumArtist: String? = nil, album: String,
    year: Int?, number: Int, disc: Int? = nil, genre: String? = nil, artwork: String? = nil,
    added: TimeInterval = 0, ext: String = "flac", format: AudioFormat = .cd
) -> Track {
    Track(
        // A folder name that must never turn up in a response.
        url: URL(fileURLWithPath: "/Volumes/secret-folder/\(album)/\(number) \(title).\(ext)"),
        title: title, artist: artist, albumArtist: albumArtist ?? artist, albumTitle: album,
        genre: genre, year: year, trackNumber: number, discNumber: disc,
        duration: 200 + Double(number), format: format, artworkID: artwork,
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000 + added))
}

private let corpus: [Track] = [
    track("Morning Static", artist: "Vera Lindqvist", album: "Sound of the Slow Hours",
          year: 2023, number: 1, genre: "Ambient", artwork: "aa11", added: 300),
    track("Slow Hours", artist: "Vera Lindqvist", album: "Sound of the Slow Hours",
          year: 2023, number: 2, genre: "Ambient", artwork: "aa11", added: 300,
          format: .hiRes),
    track("First Light", artist: "Vera Lindqvist", album: "Early Works",
          year: nil, number: 1, added: 100),
    track("Come Together", artist: "The Beatles", album: "Abbey Road",
          year: 1969, number: 1, genre: "Rock", artwork: "bb22", added: 200),
    track("Something", artist: "The Beatles", album: "Abbey Road",
          year: 1969, number: 2, genre: "Rock", artwork: "bb22", added: 200,
          ext: "mp3", format: AudioFormat(codec: .mp3, sampleRate: 44100, bitRate: 320)),
    track("Svefn-g-englar", artist: "Sigur Rós", album: "Ágætis byrjun",
          year: 1999, number: 1, genre: "Post-Rock", added: 400),
    track("Intro", artist: "2 Many DJs", album: "As Heard on Radio", year: 2002, number: 1,
          disc: 2, added: 50),
    track("Outro", artist: "2 Many DJs", album: "As Heard on Radio", year: 2002, number: 1,
          disc: 1, added: 50),
]

private func names(_ items: Any?) -> [String] {
    (items as? [[String: Any]] ?? []).compactMap { ($0["name"] ?? $0["title"]) as? String }
}

@Suite("Library endpoints")
struct LibraryEndpointTests {

    // MARK: getMusicFolders

    @Test("The library is one folder, named without saying where it is")
    func musicFolders() async throws {
        let server = try await TestLibrary(corpus).server()
        let response = await server.get("getMusicFolders")
        let folders = response.object("musicFolders")["musicFolder"] as? [[String: Any]]
        #expect(folders?.count == 1)
        #expect(folders?.first?["id"] as? Int == 1)
        #expect(folders?.first?["name"] as? String == "Library")
    }

    // MARK: getArtists

    @Test("Artists are indexed by letter, ignoring articles and accents, with # last")
    func artists() async throws {
        let server = try await TestLibrary(corpus).server()
        let artists = await server.get("getArtists").object("artists")
        #expect(artists["ignoredArticles"] as? String == "The A An")

        let index = try #require(artists["index"] as? [[String: Any]])
        #expect(index.compactMap { $0["name"] as? String } == ["B", "S", "V", "#"])
        #expect(names(index[0]["artist"]) == ["The Beatles"])
        #expect(names(index[3]["artist"]) == ["2 Many DJs"])

        let vera = try #require((index[2]["artist"] as? [[String: Any]])?.first)
        #expect(vera["id"] as? String == StableID.artist(named: "Vera Lindqvist"))
        #expect(vera["albumCount"] as? Int == 2)
        #expect(vera["coverArt"] as? String == "aa11")
    }

    @Test("An artist picture the user chose wins over an album cover")
    func customArtistImage() async throws {
        let library = try await TestLibrary(corpus)
        try await library.store.setCustomArtistImage("cc33", forArtist: "The Beatles")
        let response = await library.server().get(
            "getArtist", [("id", StableID.artist(named: "The Beatles"))])
        #expect(response.object("artist")["coverArt"] as? String == "cc33")
    }

    // MARK: getArtist

    @Test("An artist lists their albums, oldest first")
    func artist() async throws {
        let server = try await TestLibrary(corpus).server()
        let response = await server.get(
            "getArtist", [("id", StableID.artist(named: "Vera Lindqvist"))])
        let artist = response.object("artist")
        #expect(artist["name"] as? String == "Vera Lindqvist")
        #expect(artist["albumCount"] as? Int == 2)
        // No year sorts before any year.
        #expect(names(artist["album"]) == ["Early Works", "Sound of the Slow Hours"])
    }

    // MARK: getAlbum

    @Test("An album carries its details and its songs in disc and track order")
    func album() async throws {
        let server = try await TestLibrary(corpus).server()
        let key = Album.Key(albumArtist: "Vera Lindqvist", title: "Sound of the Slow Hours",
                            year: 2023)
        let album = await server.get("getAlbum", [("id", key.stableID)]).object("album")
        #expect(album["id"] as? String == key.stableID)
        #expect(album["name"] as? String == "Sound of the Slow Hours")
        #expect(album["artist"] as? String == "Vera Lindqvist")
        #expect(album["artistId"] as? String == StableID.artist(named: "Vera Lindqvist"))
        #expect(album["songCount"] as? Int == 2)
        #expect(album["duration"] as? Int == 403)
        #expect(album["year"] as? Int == 2023)
        #expect(album["genre"] as? String == "Ambient")
        #expect(album["coverArt"] as? String == "aa11")
        #expect(album["created"] as? String == "2023-11-14T22:18:20Z")
        #expect(names(album["song"]) == ["Morning Static", "Slow Hours"])
    }

    @Test("Discs come before track numbers")
    func discOrder() async throws {
        let server = try await TestLibrary(corpus).server()
        let key = Album.Key(albumArtist: "2 Many DJs", title: "As Heard on Radio", year: 2002)
        let album = await server.get("getAlbum", [("id", key.stableID)]).object("album")
        #expect(names(album["song"]) == ["Outro", "Intro"])
    }

    @Test("An album with no year leaves the year out")
    func albumWithoutYear() async throws {
        let server = try await TestLibrary(corpus).server()
        let key = Album.Key(albumArtist: "Vera Lindqvist", title: "Early Works", year: nil)
        let album = await server.get("getAlbum", [("id", key.stableID)]).object("album")
        #expect(album["name"] as? String == "Early Works")
        #expect(album["year"] == nil)
        #expect(album["coverArt"] == nil)
    }

    // MARK: getSong

    @Test("A song describes its file without saying where it is")
    func song() async throws {
        let library = try await TestLibrary(corpus)
        let stored = try #require(try await library.store.allTracks()
            .first { $0.title == "Slow Hours" })
        let id = "tr-" + stored.id.uuidString.lowercased()
        let song = await library.server().get("getSong", [("id", id)]).object("song")

        #expect(song["id"] as? String == id)
        #expect(song["title"] as? String == "Slow Hours")
        #expect(song["album"] as? String == "Sound of the Slow Hours")
        #expect(song["albumId"] as? String == stored.albumKey.stableID)
        #expect(song["parent"] as? String == stored.albumKey.stableID)
        #expect(song["artist"] as? String == "Vera Lindqvist")
        #expect(song["track"] as? Int == 2)
        #expect(song["duration"] as? Int == 202)
        #expect(song["suffix"] as? String == "flac")
        #expect(song["contentType"] as? String == "audio/flac")
        #expect(song["bitDepth"] as? Int == 24)
        #expect(song["samplingRate"] as? Int == 96000)
        #expect(song["channelCount"] as? Int == 2)
        #expect(song["isDir"] as? Bool == false)
        #expect(song["type"] as? String == "music")
        #expect(song["bitRate"] == nil)
        #expect(song["path"] == nil)
    }

    @Test("A lossy song reports its bitrate and its own content type")
    func lossySong() async throws {
        let library = try await TestLibrary(corpus)
        let stored = try #require(try await library.store.allTracks()
            .first { $0.title == "Something" })
        let song = await library.server().get(
            "getSong", [("id", "tr-" + stored.id.uuidString.lowercased())]).object("song")
        #expect(song["suffix"] as? String == "mp3")
        #expect(song["contentType"] as? String == "audio/mpeg")
        #expect(song["bitRate"] as? Int == 320)
        #expect(song["bitDepth"] == nil)
    }

    // MARK: Ids

    @Test("A missing id is a missing parameter", arguments: ["getArtist", "getAlbum", "getSong"])
    func missingID(endpoint: String) async throws {
        let server = try await TestLibrary(corpus).server()
        #expect(await server.get(endpoint).errorCode == 10)
        #expect(await server.get(endpoint, [("id", "")]).errorCode == 10)
    }

    @Test("Anything that is not an id this library issued is simply not found", arguments: [
        "nonsense", "al-", "ar-", "tr-", "al-00000000000000000000000000000000",
        "tr-00000000-0000-0000-0000-000000000000", "tr-not-a-uuid",
        "../../etc/passwd", "/Volumes/secret-folder/Abbey Road/1 Come Together.flac",
        "file:///etc/passwd", "1 OR 1=1", "'; DROP TABLE track; --", "%00", "*",
    ])
    func unknownIDs(id: String) async throws {
        let server = try await TestLibrary(corpus).server()
        for endpoint in ["getArtist", "getAlbum", "getSong"] {
            let response = await server.get(endpoint, [("id", id)])
            #expect(response.errorCode == 70, "\(endpoint) \(id)")
            #expect(response.text.contains("Not found."))
        }
    }

    @Test("An id of one kind finds nothing at an endpoint of another")
    func crossKindIDs() async throws {
        let library = try await TestLibrary(corpus)
        let server = library.server()
        let album = Album.Key(albumArtist: "The Beatles", title: "Abbey Road", year: 1969).stableID
        let artist = StableID.artist(named: "The Beatles")
        let stored = try #require(try await library.store.allTracks().first)

        #expect(await server.get("getArtist", [("id", album)]).errorCode == 70)
        #expect(await server.get("getAlbum", [("id", artist)]).errorCode == 70)
        #expect(await server.get("getSong", [("id", album)]).errorCode == 70)
        // A song id is accepted only exactly as issued.
        #expect(await server.get("getSong", [("id", stored.id.uuidString)]).errorCode == 70)
        #expect(await server.get("getSong", [("id", "tr-" + stored.id.uuidString)]).errorCode == 70)
    }

    @Test("Ids are the same after the library is scanned again")
    func idsSurviveRescan() async throws {
        let library = try await TestLibrary(corpus)
        let server = library.server()
        let before = await server.get("search3", [("query", ""), ("songCount", "500")]).body

        // A rescan reads every file afresh: same paths, new in-memory ids.
        try await library.store.upsert(corpus.map {
            track($0.title, artist: $0.artist, album: $0.albumTitle, year: $0.year,
                  number: $0.trackNumber ?? 0, disc: $0.discNumber, genre: $0.genre,
                  artwork: $0.artworkID,
                  added: $0.dateAdded.timeIntervalSince1970 - 1_700_000_000,
                  ext: $0.url.pathExtension, format: $0.format)
        })
        let after = await server.get("search3", [("query", ""), ("songCount", "500")]).body
        #expect(before == after)
    }

    // MARK: getAlbumList2

    @Test("Albums page through in title order without gaps or repeats")
    func albumListPaging() async throws {
        let server = try await TestLibrary(corpus).server()
        func page(_ offset: Int) async -> [String] {
            names(await server.get("getAlbumList2", [
                ("type", "alphabeticalByName"), ("size", "2"), ("offset", "\(offset)"),
            ]).object("albumList2")["album"])
        }
        #expect(await page(0) == ["Abbey Road", "Ágætis byrjun"])
        #expect(await page(2) == ["As Heard on Radio", "Early Works"])
        #expect(await page(4) == ["Sound of the Slow Hours"])
        #expect(await page(6) == [])
    }

    @Test("The other orderings")
    func albumListOrderings() async throws {
        let server = try await TestLibrary(corpus).server()
        func list(_ query: [(String, String)]) async -> [String] {
            names(await server.get("getAlbumList2", query + [("size", "50")])
                .object("albumList2")["album"])
        }
        #expect(await list([("type", "newest")]) == [
            "Ágætis byrjun", "Sound of the Slow Hours", "Abbey Road", "Early Works",
            "As Heard on Radio",
        ])
        #expect(await list([("type", "alphabeticalByArtist")]) == [
            "As Heard on Radio", "Abbey Road", "Ágætis byrjun", "Early Works",
            "Sound of the Slow Hours",
        ])
        #expect(await list([("type", "byYear"), ("fromYear", "1960"), ("toYear", "2002")])
                == ["Abbey Road", "Ágætis byrjun", "As Heard on Radio"])
        #expect(await list([("type", "byYear"), ("fromYear", "2002"), ("toYear", "1960")])
                == ["As Heard on Radio", "Ágætis byrjun", "Abbey Road"])
        #expect(await list([("type", "byGenre"), ("genre", "post-rock")]) == ["Ágætis byrjun"])
        #expect(await list([("type", "byGenre"), ("genre", "Polka")]) == [])
        #expect(Set(await list([("type", "random")])).count == 5)
        // Defined by the protocol, not kept by this library: empty, not an error.
        #expect(await list([("type", "starred")]) == [])
    }

    @Test("List parameters are checked")
    func albumListParameters() async throws {
        let server = try await TestLibrary(corpus).server()
        #expect(await server.get("getAlbumList2").errorCode == 10)
        #expect(await server.get("getAlbumList2", [("type", "everything")]).errorCode == 10)
        #expect(await server.get("getAlbumList2", [("type", "byYear")]).errorCode == 10)
        #expect(await server.get("getAlbumList2", [("type", "byGenre")]).errorCode == 10)
        for bad in ["abc", "-1", "1.5", " 2", "", "99999999999999999999"] {
            #expect(await server.get("getAlbumList2",
                                     [("type", "newest"), ("size", bad)]).errorCode == 10)
            #expect(await server.get("getAlbumList2",
                                     [("type", "newest"), ("offset", bad)]).errorCode == 10)
        }
        // More than the maximum is brought down to it, not refused.
        let huge = await server.get("getAlbumList2", [("type", "newest"), ("size", "100000")])
        #expect(names(huge.object("albumList2")["album"]).count == 5)
    }

    // MARK: search3

    @Test("A search finds songs, albums and artists")
    func search() async throws {
        let server = try await TestLibrary(corpus).server()
        let result = await server.get("search3", [("query", "slow")]).object("searchResult3")
        // Both songs: one by its title, the other because its album matches.
        #expect(Set(names(result["song"])) == ["Slow Hours", "Morning Static"])
        #expect(names(result["album"]) == ["Sound of the Slow Hours"])
        #expect(names(result["artist"]) == [])

        let beatles = await server.get("search3", [("query", "beatles")]).object("searchResult3")
        #expect(names(beatles["artist"]) == ["The Beatles"])
        #expect(names(beatles["album"]) == ["Abbey Road"])
        #expect(Set(names(beatles["song"])) == ["Come Together", "Something"])
    }

    @Test("Search ignores case and accents")
    func searchFolding() async throws {
        let server = try await TestLibrary(corpus).server()
        let result = await server.get("search3", [("query", "SIGUR ros")]).object("searchResult3")
        #expect(names(result["artist"]) == ["Sigur Rós"])
        #expect(names(result["album"]) == ["Ágætis byrjun"])
        #expect(names(result["song"]) == ["Svefn-g-englar"])
    }

    @Test("An empty query is the whole library, a page at a time", arguments: ["", "\"\""])
    func searchEverything(query: String) async throws {
        let server = try await TestLibrary(corpus).server()
        let all = await server.get("search3", [
            ("query", query), ("artistCount", "500"), ("albumCount", "500"), ("songCount", "500"),
        ]).object("searchResult3")
        #expect(names(all["artist"]).count == 4)
        #expect(names(all["album"]).count == 5)
        #expect(names(all["song"]).count == corpus.count)

        var songs: [String] = []
        for offset in stride(from: 0, to: 12, by: 3) {
            let page = await server.get("search3", [
                ("query", query), ("songCount", "3"), ("songOffset", "\(offset)"),
                ("artistCount", "0"), ("albumCount", "0"),
            ]).object("searchResult3")
            #expect(names(page["artist"]).isEmpty)
            songs += names(page["song"])
        }
        #expect(songs.count == corpus.count)
        #expect(Set(songs).count == Set(corpus.map(\.title)).count)
    }

    @Test("Search needs a query, and takes anything as one")
    func searchInput() async throws {
        let server = try await TestLibrary(corpus).server()
        #expect(await server.get("search3").errorCode == 10)
        for query in ["\"", "*", "a OR b", "NEAR(", "title:slow", "'; DROP TABLE track; --",
                      "🎧", String(repeating: "a ", count: 200)] {
            #expect(await server.get("search3", [("query", query)]).isOK, "\(query)")
        }
        #expect(await server.get("search3", [("query", "x"), ("songCount", "many")]).errorCode == 10)
    }

    // MARK: Across every endpoint

    @Test("Every library endpoint needs a key", arguments: [
        "getMusicFolders", "getArtists", "getArtist", "getAlbum", "getAlbumList2", "getSong",
        "search3",
    ])
    func needsKey(endpoint: String) async throws {
        let server = try await TestLibrary(corpus).server()
        let response = await server.get(endpoint, [("id", "x"), ("query", ""), ("type", "newest")],
                                        authenticated: false)
        #expect(response.errorCode == 44)
        #expect(!response.text.contains("Vera"))
    }

    @Test("No response says where a file is")
    func noPaths() async throws {
        let library = try await TestLibrary(corpus)
        let server = library.server()
        let stored = try #require(try await library.store.allTracks().first)
        let album = Album.Key(albumArtist: "The Beatles", title: "Abbey Road", year: 1969).stableID
        let responses = [
            await server.get("getMusicFolders"),
            await server.get("getArtists"),
            await server.get("getArtist", [("id", StableID.artist(named: "The Beatles"))]),
            await server.get("getAlbum", [("id", album)]),
            await server.get("getSong", [("id", "tr-" + stored.id.uuidString.lowercased())]),
            await server.get("getAlbumList2", [("type", "newest"), ("size", "500")]),
            await server.get("search3", [("query", ""), ("songCount", "500")]),
            await server.get("getSong", [("id", "/Volumes/secret-folder/x.flac")]),
        ]
        for response in responses {
            #expect(!response.text.contains("secret-folder"))
            #expect(!response.text.contains("/Volumes"))
            #expect(!response.text.contains("file:"))
            #expect(!response.text.contains("\"path\""))
        }
    }

    @Test("An empty library answers every list with nothing, not an error")
    func emptyLibrary() async throws {
        let server = try await TestLibrary().server()
        #expect((await server.get("getArtists").object("artists")["index"] as? [Any])?.isEmpty == true)
        #expect(await server.get("getAlbumList2", [("type", "newest")]).isOK)
        #expect(await server.get("search3", [("query", "")]).isOK)
        #expect(await server.get("search3", [("query", "anything")]).isOK)
    }
}
