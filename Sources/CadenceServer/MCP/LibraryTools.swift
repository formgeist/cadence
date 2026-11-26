import Foundation
import CadenceCore
import CadenceLibrary

/// The read tools: what an agent looks at before it changes anything.
///
/// They read `SQLiteLibraryStore` directly. A read needs nothing from the
/// app's state, and the store is safe to read from any task. The write tools
/// go through the app instead, so the window shows what they did.
public struct LibraryTools: MCPToolHandler {

    /// Put in front of the model by `initialize`.
    public static let instructions = """
        Cadence is a music library on this Mac. Albums, artists and tracks are \
        named by ids: a UUID for a track, al-… for an album, ar-… for an artist. \
        Tools take the ids other tools return; look things up before acting on them. \
        Lists come a page at a time: pass nextOffset as offset for more. \
        listening_history is the best guide to what the user likes.
        """

    private let library: SQLiteLibraryStore
    private let now: @Sendable () -> Date

    public init(library: SQLiteLibraryStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.library = library
        self.now = now
    }

    // MARK: - Descriptions

    public var tools: [MCPTool] {
        [
            MCPTool(
                name: "search_tracks", title: "Search tracks",
                description: """
                    Finds tracks by words in the title, artist, album or composer, narrowed by \
                    filters. Give a query, a filter, or both. A query returns at most the \
                    100 best matches before filtering.
                    """,
                inputSchema: Schema.object([
                    "query": Schema.string("Words to look for."),
                    "artist": Schema.string("Only tracks whose artist or album artist contains this."),
                    "album": Schema.string("Only tracks whose album title contains this."),
                    "genre": Schema.string("Only tracks whose genre contains this."),
                    "yearFrom": Schema.integer("Only tracks from this year or later."),
                    "yearTo": Schema.integer("Only tracks from this year or earlier."),
                    "limit": Schema.limit, "offset": Schema.offset,
                ]),
                annotations: .readOnly),
            MCPTool(
                name: "list_artists", title: "List artists",
                description: "Album artists in the library, alphabetically.",
                inputSchema: Schema.object(["limit": Schema.limit, "offset": Schema.offset]),
                annotations: .readOnly),
            MCPTool(
                name: "list_albums", title: "List albums",
                description: "Albums in the library, optionally one artist's, one genre's or one decade's.",
                inputSchema: Schema.object([
                    "artistID": Schema.string("An ar-… id from list_artists."),
                    "genre": Schema.string("Only albums with a genre containing this."),
                    "decade": Schema.integer("The decade's first year, like 1970."),
                    "sort": Schema.choice("Order. Default artist.", CatalogSort.allCases.map(\.rawValue)),
                    "limit": Schema.limit, "offset": Schema.offset,
                ]),
                annotations: .readOnly),
            MCPTool(
                name: "get_album", title: "Get album",
                description: "One album with its tracks in order, and the user's memories of it.",
                inputSchema: Schema.object(["id": Schema.string("An al-… album id.")], required: ["id"]),
                annotations: .readOnly),
            MCPTool(
                name: "listening_history", title: "Listening history",
                description: """
                    What the user played, between two dates. Grouped by album by default, \
                    most played first; groupBy play lists each play, newest first.
                    """,
                inputSchema: Schema.object([
                    "from": Schema.string("ISO 8601 date or date-time. Default 30 days ago."),
                    "to": Schema.string("ISO 8601 date or date-time. Default now."),
                    "groupBy": Schema.choice("Default album.", ["album", "artist", "track", "play"]),
                    "limit": Schema.limit,
                ]),
                annotations: .readOnly),
            MCPTool(
                name: "liked_tracks", title: "Liked songs",
                description: "The user's liked songs, most recently liked first.",
                inputSchema: Schema.object(["limit": Schema.limit, "offset": Schema.offset]),
                annotations: .readOnly),
            MCPTool(
                name: "list_playlists", title: "List playlists",
                description: "Every playlist, in sidebar order, and the folders they are filed in.",
                inputSchema: Schema.object([:]),
                annotations: .readOnly),
            MCPTool(
                name: "get_playlist", title: "Get playlist",
                description: """
                    One playlist's tracks in order. position is the track's place in the \
                    playlist, counting from 0; a track can appear more than once.
                    """,
                inputSchema: Schema.object([
                    "id": Schema.string("A playlist id."),
                    "limit": Schema.limit, "offset": Schema.offset,
                ], required: ["id"]),
                annotations: .readOnly),
            MCPTool(
                name: "list_catalogs", title: "List catalogs",
                description: """
                    Catalogs: shelves of albums picked out by rules, kept current as the \
                    library changes. Each with its rules and how many albums it holds now.
                    """,
                inputSchema: Schema.object([:]),
                annotations: .readOnly),
            MCPTool(
                name: "preview_catalog", title: "Preview catalog",
                description: """
                    The albums a catalog definition would hold, without saving anything. \
                    Use it to check rules before saving a catalog.
                    """,
                inputSchema: Schema.object([
                    "definition": CatalogInput.schema,
                    "limit": Schema.limit, "offset": Schema.offset,
                ], required: ["definition"]),
                annotations: .readOnly),
            MCPTool(
                name: "list_memories", title: "List memories",
                description: """
                    The user's memories: short notes kept on an album or a song, newest first.
                    """,
                inputSchema: Schema.object([
                    "albumID": Schema.string("Only memories of this al-… album."),
                    "limit": Schema.limit, "offset": Schema.offset,
                ]),
                annotations: .readOnly),
        ]
    }

    // MARK: - Calls

    public func call(_ name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let allowed = Set(tools.first { $0.name == name }?
            .inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let arguments = try MCPArguments(arguments, allowed: allowed)
        switch name {
        case "search_tracks": return try await searchTracks(arguments)
        case "list_artists": return try await listArtists(arguments)
        case "list_albums": return try await listAlbums(arguments)
        case "get_album": return try await getAlbum(arguments)
        case "listening_history": return try await listeningHistory(arguments)
        case "liked_tracks": return try await likedTracks(arguments)
        case "list_playlists": return try await listPlaylists()
        case "get_playlist": return try await getPlaylist(arguments)
        case "list_catalogs": return try await listCatalogs()
        case "preview_catalog": return try await previewCatalog(arguments)
        case "list_memories": return try await listMemories(arguments)
        default: throw MCPToolError("Unknown tool.")
        }
    }

    private func searchTracks(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let query = try arguments.string("query")
        let artist = try arguments.string("artist").map(Self.fold)
        let album = try arguments.string("album").map(Self.fold)
        let genre = try arguments.string("genre").map(Self.fold)
        let yearFrom = try arguments.int("yearFrom")
        let yearTo = try arguments.int("yearTo")
        let (limit, offset) = try arguments.page()
        guard query != nil || artist != nil || album != nil || genre != nil
                || yearFrom != nil || yearTo != nil else {
            throw MCPToolError("Give a query or at least one filter.")
        }

        var tracks: [Track]
        if let query {
            tracks = try await library.tracks(matching: query)
        } else {
            tracks = try await library.allTracks().sorted { a, b in
                if a.albumArtist != b.albumArtist {
                    return a.albumArtist.localizedStandardCompare(b.albumArtist) == .orderedAscending
                }
                if a.albumKey != b.albumKey {
                    return a.albumTitle.localizedStandardCompare(b.albumTitle) == .orderedAscending
                }
                return Track.inAlbumOrder(a, b)
            }
        }
        tracks = tracks.filter { track in
            if let artist, !Self.fold(track.artist).contains(artist),
               !Self.fold(track.albumArtist).contains(artist) { return false }
            if let album, !Self.fold(track.albumTitle).contains(album) { return false }
            if let genre, !Self.fold(track.genre ?? "").contains(genre) { return false }
            if let yearFrom, (track.year ?? Int.min) < yearFrom { return false }
            if let yearTo, (track.year ?? Int.max) > yearTo { return false }
            return true
        }

        let liked = Set(try await library.likedTrackIDs())
        let page = Page(tracks, limit: limit, offset: offset)
        return MCPToolResult(text: page.summary("tracks"), structured: page.json("tracks") {
            LibraryJSON.track($0, liked: liked.contains($0.id))
        })
    }

    private func listArtists(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let (limit, offset) = try arguments.page()
        let page = Page(try await library.artists(), limit: limit, offset: offset)
        return MCPToolResult(text: page.summary("artists"),
                             structured: page.json("artists", LibraryJSON.artist))
    }

    private func listAlbums(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let artistName: String?
        if let artistID = try arguments.string("artistID") {
            guard let name = try await library.artistName(forStableID: artistID) else {
                throw MCPToolError("No artist has the id \(artistID.prefix(40)).")
            }
            artistName = name
        } else {
            artistName = nil
        }
        let genre = try arguments.string("genre").map(Self.fold)
        let decade = try arguments.int("decade")
        let sort = try arguments.choice("sort", from: CatalogSort.allCases.map(\.rawValue))
            .flatMap(CatalogSort.init(rawValue:)) ?? .artist
        let (limit, offset) = try arguments.page()

        let albums = try await library.albumSummaries(byArtist: artistName).filter { album in
            if let genre, !album.genres.contains(where: { Self.fold($0).contains(genre) }) {
                return false
            }
            if let decade {
                guard let year = album.key.year, year / 10 * 10 == decade / 10 * 10 else { return false }
            }
            return true
        }
        let page = Page(Self.sorted(albums, by: sort), limit: limit, offset: offset)
        return MCPToolResult(text: page.summary("albums"),
                             structured: page.json("albums", LibraryJSON.album))
    }

    private func getAlbum(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let id = try arguments.requiredString("id")
        guard let key = try await library.albumKey(forStableID: id),
              let album = try await library.album(for: key) else {
            throw MCPToolError("No album has the id \(id.prefix(40)).")
        }
        let tracks = album.tracks.sorted(by: Track.inAlbumOrder)
        let liked = Set(try await library.likedTrackIDs())
        let memories = try await library.memories().filter { $0.subject.albumKey == key }

        guard case .object(var object) = LibraryJSON.album(album) else { return .failure("Internal error.") }
        object["genre"] = LibraryJSON.optional(tracks.compactMap { $0.genre }.first)
        object["label"] = LibraryJSON.optional(tracks.compactMap { $0.label }.first)
        object["format"] = tracks.first.map { .string($0.format.badgeDescription) } ?? .null
        object["tracks"] = .array(tracks.map { LibraryJSON.track($0, liked: liked.contains($0.id)) })
        object["memories"] = .array(memories.map(LibraryJSON.memory))
        let year = album.year.map { " (\($0))" } ?? ""
        return MCPToolResult(
            text: "\(album.title) by \(album.albumArtist)\(year), \(tracks.count) tracks.",
            structured: .object(object))
    }

    private func listeningHistory(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let to = try arguments.date("to") ?? now()
        let from = try arguments.date("from") ?? to.addingTimeInterval(-30 * 24 * 60 * 60)
        guard from <= to else { throw MCPToolError("“from” must be before “to”.") }
        let groupBy = try arguments.choice("groupBy", from: ["album", "artist", "track", "play"]) ?? "album"
        let limit = try arguments.int("limit", in: 1...500) ?? 50

        let plays = try await library.allPlays().filter { $0.playedAt >= from && $0.playedAt <= to }
        let window: [String: JSONValue] = [
            "from": LibraryJSON.date(from), "to": LibraryJSON.date(to),
            "playCount": .integer(plays.count),
        ]

        // Track ids, for the groupings that name a song: a play names what
        // it was, not a row, so it is matched back to the library here.
        var trackIDs: [String: Track.ID] = [:]
        if groupBy == "track" || groupBy == "play" {
            for track in try await library.allTracks() {
                trackIDs[Self.songKey(track.title, track.artist, track.albumKey)] = track.id
            }
        }
        func song(_ play: PlayRecord) -> [String: JSONValue] {
            let album = Album.Key(albumArtist: play.albumArtist, title: play.albumTitle,
                                  year: play.albumYear)
            return [
                "title": .string(play.title), "artist": .string(play.artist),
                "album": .string(play.albumTitle), "albumID": .string(album.stableID),
                // Nil for a song no longer in the library.
                "trackID": LibraryJSON.optional(
                    trackIDs[Self.songKey(play.title, play.artist, album)]?.uuidString),
            ]
        }

        if groupBy == "play" {
            let recent = plays.reversed().prefix(limit)
            var object = window
            object["plays"] = .array(recent.map { play in
                var entry = song(play)
                entry["playedAt"] = LibraryJSON.date(play.playedAt)
                return .object(entry)
            })
            return MCPToolResult(text: "\(plays.count) plays; the \(recent.count) most recent.",
                                 structured: .object(object))
        }

        struct Group { var count = 0; var last = Date.distantPast; var entry: [String: JSONValue] = [:] }
        var groups: [String: Group] = [:]
        for play in plays {
            let key: String
            let entry: [String: JSONValue]
            switch groupBy {
            case "artist":
                key = play.albumArtist
                entry = ["artist": .string(play.albumArtist),
                         "artistID": .string(StableID.artist(named: play.albumArtist))]
            case "track":
                let album = Album.Key(albumArtist: play.albumArtist, title: play.albumTitle,
                                      year: play.albumYear)
                key = Self.songKey(play.title, play.artist, album)
                entry = song(play)
            default:
                let album = Album.Key(albumArtist: play.albumArtist, title: play.albumTitle,
                                      year: play.albumYear)
                key = album.stableID
                entry = ["album": .string(play.albumTitle), "albumArtist": .string(play.albumArtist),
                         "albumID": .string(album.stableID), "year": LibraryJSON.optional(play.albumYear)]
            }
            var group = groups[key] ?? Group(entry: entry)
            group.count += 1
            group.last = max(group.last, play.playedAt)
            groups[key] = group
        }
        let ranked = groups.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
            .prefix(limit)
        var object = window
        object["groupBy"] = .string(groupBy)
        object["groupCount"] = .integer(groups.count)
        object["groups"] = .array(ranked.map { group in
            var entry = group.entry
            entry["plays"] = .integer(group.count)
            entry["lastPlayed"] = LibraryJSON.date(group.last)
            return .object(entry)
        })
        return MCPToolResult(
            text: "\(plays.count) plays across \(groups.count) \(groupBy == "track" ? "songs" : groupBy + "s").",
            structured: .object(object))
    }

    private func likedTracks(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let (limit, offset) = try arguments.page()
        let page = Page(try await library.likedTracks(), limit: limit, offset: offset)
        let tracks = try await library.tracks(withIDs: page.items.map(\.id))
        let structured = page.json("tracks") { liked in
            guard let track = tracks[liked.id],
                  case .object(var object) = LibraryJSON.track(track) else { return .null }
            object["likedAt"] = LibraryJSON.date(liked.likedAt)
            return .object(object)
        }
        return MCPToolResult(text: page.summary("liked songs"), structured: structured)
    }

    private func listPlaylists() async throws -> MCPToolResult {
        let playlists = try await library.playlists()
        let folders = try await library.playlistFolders()
        return MCPToolResult(
            text: "\(playlists.count) playlists in \(folders.count) folders.",
            structured: ["playlists": .array(playlists.map(LibraryJSON.playlist)),
                         "folders": .array(folders.map(LibraryJSON.folder))])
    }

    private func getPlaylist(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let id = try arguments.requiredUUID("id")
        let (limit, offset) = try arguments.page(defaultLimit: 100, maximumLimit: 500)
        guard let playlist = try await library.playlists().first(where: { $0.id == id }) else {
            throw MCPToolError("No playlist has the id \(id.uuidString).")
        }
        let page = Page(Array(playlist.trackIDs.enumerated()), limit: limit, offset: offset)
        let tracks = try await library.tracks(withIDs: page.items.map(\.element))
        let liked = Set(try await library.likedTrackIDs())
        guard case .object(var object) = LibraryJSON.playlist(playlist),
              case .object(let items) = page.json("tracks", { position, trackID in
                  guard let track = tracks[trackID],
                        case .object(var entry) = LibraryJSON.track(track, liked: liked.contains(trackID))
                  else { return .null }
                  entry["position"] = .integer(position)
                  return .object(entry)
              }) else { return .failure("Internal error.") }
        object.merge(items) { _, new in new }
        return MCPToolResult(text: "\(playlist.name): " + page.summary("tracks"),
                             structured: .object(object))
    }

    private func listCatalogs() async throws -> MCPToolResult {
        let catalogs = try await library.catalogs()
        let albums = catalogs.isEmpty ? [] : try await library.albums()
        let context = Catalog.Context(playlists: catalogs.isEmpty ? [] : try await library.playlists())
        let date = now()
        return MCPToolResult(
            text: "\(catalogs.count) catalogs.",
            structured: ["catalogs": .array(catalogs.map {
                LibraryJSON.catalog($0, albumCount: $0.definition.albums(
                    from: albums, now: date, context: context).count, context: context)
            })])
    }

    private func previewCatalog(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let definition = try CatalogInput.definition(from: arguments.raw("definition"))
        let (limit, offset) = try arguments.page()
        let context = try await CatalogInput.context(for: definition, in: library)
        let matched = definition.albums(from: try await library.albums(), now: now(), context: context)
        let page = Page(matched, limit: limit, offset: offset)
        guard case .object(var object) = page.json("albums", LibraryJSON.album) else {
            return .failure("Internal error.")
        }
        object["definition"] = LibraryJSON.definition(definition, context: context)
        return MCPToolResult(text: "\(definition.summary(in: context)): " + page.summary("albums"),
                             structured: .object(object))
    }

    private func listMemories(_ arguments: MCPArguments) async throws -> MCPToolResult {
        let albumID = try arguments.string("albumID")
        let (limit, offset) = try arguments.page()
        let memories = try await library.memories().filter {
            albumID == nil || $0.subject.albumKey.stableID == albumID
        }
        let page = Page(memories, limit: limit, offset: offset)
        return MCPToolResult(text: page.summary("memories"),
                             structured: page.json("memories", LibraryJSON.memory))
    }

    // MARK: - Helpers

    /// Case and accents ignored, the way catalog rules compare text.
    static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func songKey(_ title: String, _ artist: String, _ album: Album.Key) -> String {
        [title, artist, album.stableID].joined(separator: "\u{1F}")
    }

    /// `CatalogSort`'s orders, over summaries rather than whole albums.
    private static func sorted(_ albums: [SQLiteLibraryStore.AlbumSummary],
                               by sort: CatalogSort) -> [SQLiteLibraryStore.AlbumSummary] {
        func byArtist(_ a: SQLiteLibraryStore.AlbumSummary, _ b: SQLiteLibraryStore.AlbumSummary) -> Bool {
            let order = Artist.stripArticle(a.key.albumArtist)
                .localizedStandardCompare(Artist.stripArticle(b.key.albumArtist))
            if order != .orderedSame { return order == .orderedAscending }
            if a.key.year != b.key.year { return (a.key.year ?? 0) < (b.key.year ?? 0) }
            return a.key.title.localizedStandardCompare(b.key.title) == .orderedAscending
        }
        switch sort {
        case .artist:
            return albums.sorted(by: byArtist)
        case .title:
            return albums.sorted {
                let order = $0.key.title.localizedStandardCompare($1.key.title)
                return order == .orderedSame ? byArtist($0, $1) : order == .orderedAscending
            }
        case .yearOldest, .yearNewest:
            let newest = sort == .yearNewest
            return albums.sorted { a, b in
                switch (a.key.year, b.key.year) {
                case let (x?, y?) where x != y: return newest ? x > y : x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return byArtist(a, b)
                }
            }
        case .recentlyAdded:
            return albums.sorted {
                $0.dateAdded != $1.dateAdded ? $0.dateAdded > $1.dateAdded : byArtist($0, $1)
            }
        }
    }
}
