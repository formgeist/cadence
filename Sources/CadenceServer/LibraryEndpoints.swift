import Foundation
import CadenceCore
import CadenceLibrary

/// What each browse endpoint answers. Every function here reads; none writes.
///
/// A function returns the payload on success and throws `EndpointFailure` for
/// a refusal the client should be told about. Anything else it throws came
/// from the store, and `LibraryServer` reports that as a generic failure with
/// no detail.
struct EndpointFailure: Error {
    var code: SubsonicResponse.ErrorCode
    var message: String

    static func missing(_ parameter: String) -> EndpointFailure {
        EndpointFailure(code: .missingParameter,
                        message: "Required parameter is missing: \(parameter).")
    }

    static func invalid(_ parameter: String) -> EndpointFailure {
        EndpointFailure(code: .missingParameter,
                        message: "Parameter is not valid: \(parameter).")
    }

    /// One answer for an id that is malformed, of the wrong kind, never
    /// issued, or no longer in the library. A client cannot tell which.
    static let notFound = EndpointFailure(code: .notFound, message: "Not found.")
}

struct LibraryEndpoints: Sendable {
    let library: SQLiteLibraryStore
    /// Nil where there is no artwork to serve; `getCoverArt` then finds nothing.
    let artwork: DiskArtworkStore?

    /// The most a single response lists, whatever the client asks for.
    static let maximumPageSize = 500

    // MARK: - getMusicFolders

    /// The whole library is shared as one folder. Its name says nothing about
    /// where on disk the music is.
    func musicFolders() -> MusicFolders {
        MusicFolders(musicFolder: [.init(id: 1, name: "Library")])
    }

    // MARK: - getArtists

    func artists() async throws -> ArtistIndexes {
        let items = try await artistItems()
        let grouped = Dictionary(grouping: items) { Self.indexLetter(for: $0.name) }
        let index = grouped.keys.sorted { a, b in
            // "#" (everything that does not start with a letter) goes last.
            if (a == "#") != (b == "#") { return b == "#" }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { ArtistIndexes.Index(name: $0, artist: grouped[$0] ?? []) }
        return ArtistIndexes(ignoredArticles: "The A An", index: index)
    }

    /// Every artist, in the store's order, each with the picture the Mac app
    /// shows: the one the user chose, else a cover from one of their albums.
    private func artistItems() async throws -> [ArtistItem] {
        let artists = try await library.artists()
        let custom = try await library.customArtistImages()
        var covers: [String: Artwork.ID] = [:]
        for summary in try await library.albumSummaries().sorted(by: Self.byYear) {
            guard let artwork = summary.artworkID,
                  covers[summary.key.albumArtist] == nil else { continue }
            covers[summary.key.albumArtist] = artwork
        }
        return artists.map { ArtistItem($0, coverArt: custom[$0.name] ?? covers[$0.name]) }
    }

    static func indexLetter(for name: String) -> String {
        let folded = Artist.stripArticle(name)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
        guard let first = folded.first, first.isLetter else { return "#" }
        return String(first)
    }

    // MARK: - getArtist

    func artist(_ request: HTTPRequest) async throws -> ArtistItem {
        let id = try Self.required("id", in: request)
        guard let name = try await library.artistName(forStableID: id) else {
            throw EndpointFailure.notFound
        }
        let summaries = try await library.albumSummaries(byArtist: name)
        // The id table remembers artists whose music has left the library.
        guard !summaries.isEmpty else { throw EndpointFailure.notFound }
        let custom = try await library.customArtistImages()[name]
        let albums = summaries.sorted(by: Self.byYear)
        let artist = Artist(name: name, albumCount: summaries.count,
                            trackCount: summaries.reduce(0) { $0 + $1.trackCount }, formats: [])
        return ArtistItem(artist,
                          coverArt: custom ?? albums.compactMap(\.artworkID).first,
                          albums: albums.map(AlbumItem.init))
    }

    // MARK: - getAlbum

    func album(_ request: HTTPRequest) async throws -> AlbumItem {
        let id = try Self.required("id", in: request)
        guard let key = try await library.albumKey(forStableID: id),
              let album = try await library.album(for: key) else {
            throw EndpointFailure.notFound
        }
        return AlbumItem(album)
    }

    // MARK: - getSong

    func song(_ request: HTTPRequest) async throws -> SongItem {
        let id = try Self.required("id", in: request)
        guard let trackID = WireID.track(from: id),
              let track = try await library.track(withID: trackID) else {
            throw EndpointFailure.notFound
        }
        return SongItem(track)
    }

    // MARK: - getAlbumList2

    func albumList(_ request: HTTPRequest) async throws -> AlbumList {
        let type = try Self.required("type", in: request)
        let size = try Self.integer("size", in: request, default: 10,
                                    range: 1...Self.maximumPageSize)
        let offset = try Self.integer("offset", in: request, default: 0, range: 0...10_000_000)
        var summaries = try await library.albumSummaries()

        switch type {
        case "alphabeticalByName":
            summaries.sort(by: Self.byTitle)
        case "alphabeticalByArtist":
            summaries.sort(by: Self.byArtist)
        case "newest":
            summaries.sort {
                $0.dateAdded != $1.dateAdded ? $0.dateAdded > $1.dateAdded : Self.byTitle($0, $1)
            }
        case "byYear":
            let from = try Self.integer("fromYear", in: request, default: nil, range: 0...9999)
            let to = try Self.integer("toYear", in: request, default: nil, range: 0...9999)
            guard let from, let to else {
                throw EndpointFailure.missing(from == nil ? "fromYear" : "toYear")
            }
            let span = min(from, to)...max(from, to)
            summaries = summaries.filter { $0.key.year.map(span.contains) ?? false }
            summaries.sort(by: Self.byYear)
            // The protocol reads a reversed range as "newest first".
            if from > to { summaries.reverse() }
        case "byGenre":
            let genre = Self.fold(try Self.required("genre", in: request))
            summaries = summaries.filter { $0.genres.contains { Self.fold($0) == genre } }
            summaries.sort(by: Self.byTitle)
        case "random":
            summaries.shuffle()
        case "recent", "frequent", "highest", "starred":
            // Lists the protocol defines over ratings and play counts by
            // album id, which this library does not keep in that form.
            // Answered as empty, which the protocol allows, so a client that
            // asks is not handed an error.
            summaries = []
        default:
            throw EndpointFailure.invalid("type")
        }

        return AlbumList(album: Self.page(summaries, offset: offset, count: size)
            .map(AlbumItem.init))
    }

    // MARK: - search3

    func search(_ request: HTTPRequest) async throws -> SearchResult {
        // The protocol requires `query`, and defines an empty one (which some
        // clients spell as two quote marks) as "everything", for a client
        // that wants the whole library a page at a time.
        guard let raw = request.parameter("query") else { throw EndpointFailure.missing("query") }
        let query = raw == "\"\"" ? "" : raw.trimmingCharacters(in: .whitespaces)

        let artistCount = try Self.integer("artistCount", in: request, default: 20,
                                           range: 0...Self.maximumPageSize)
        let artistOffset = try Self.integer("artistOffset", in: request, default: 0,
                                            range: 0...10_000_000)
        let albumCount = try Self.integer("albumCount", in: request, default: 20,
                                          range: 0...Self.maximumPageSize)
        let albumOffset = try Self.integer("albumOffset", in: request, default: 0,
                                           range: 0...10_000_000)
        let songCount = try Self.integer("songCount", in: request, default: 20,
                                         range: 0...Self.maximumPageSize)
        let songOffset = try Self.integer("songOffset", in: request, default: 0,
                                          range: 0...10_000_000)

        let terms = Self.terms(in: query)
        var artists = artistCount > 0 ? try await artistItems() : []
        var albums = albumCount > 0
            ? try await library.albumSummaries().sorted(by: Self.byTitle) : []

        let songs: [Track]
        if terms.isEmpty {
            songs = songCount > 0
                ? try await library.tracks(offset: songOffset, limit: songCount) : []
        } else {
            artists = artists.filter { Self.matches($0.name, terms) }
            albums = albums.filter {
                Self.matches($0.key.title + " " + $0.key.albumArtist, terms)
            }
            // The store's own full-text search, the one the Mac app uses. It
            // builds its pattern from the letters and digits of the query
            // alone, so nothing a client sends reaches the query syntax.
            let hits = songCount > 0 ? try await library.tracks(matching: query) : []
            songs = Self.page(hits, offset: songOffset, count: songCount)
        }

        return SearchResult(
            artist: Self.page(artists, offset: artistOffset, count: artistCount),
            album: Self.page(albums, offset: albumOffset, count: albumCount).map(AlbumItem.init),
            song: songs.map { SongItem($0) })
    }

    // MARK: - getPlaylists, getPlaylist

    /// Every playlist, in the Mac's sidebar order. Sidebar folders have no
    /// counterpart in the protocol, so the list is flat.
    func playlists() async throws -> Playlists {
        Playlists(playlist: try await library.playlists().map { PlaylistItem($0) })
    }

    func playlist(_ request: HTTPRequest) async throws -> PlaylistItem {
        let id = try Self.required("id", in: request)
        guard let playlistID = WireID.playlist(from: id),
              let playlist = try await library.playlists().first(where: { $0.id == playlistID })
        else { throw EndpointFailure.notFound }
        // In playlist order, the same song twice where the playlist has it
        // twice.
        let tracks = try await library.tracks(withIDs: playlist.trackIDs)
        return PlaylistItem(playlist, songs: playlist.trackIDs.compactMap { tracks[$0] })
    }

    // MARK: - getStarred2

    /// Liked Songs, most recently liked first. The Mac likes songs only, so
    /// the protocol's starred artists and albums are always empty.
    func starred() async throws -> Starred {
        let likes = try await library.likedTracks()
        let tracks = try await library.tracks(withIDs: likes.map(\.id))
        return Starred(artist: [], album: [], song: likes.compactMap { like in
            tracks[like.id].map { SongItem($0, starred: like.likedAt) }
        })
    }

    // MARK: - Parameters

    static func required(_ name: String, in request: HTTPRequest) throws -> String {
        guard let value = request.parameter(name), !value.isEmpty else {
            throw EndpointFailure.missing(name)
        }
        return value
    }

    /// An integer parameter. Absent means `default`; present but not a plain
    /// integer is an error; a value outside `range` is brought to its nearest
    /// end, so asking for a million rows gets the maximum, not a refusal.
    static func integer(
        _ name: String, in request: HTTPRequest, default fallback: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        try integer(name, in: request, default: Optional(fallback), range: range) ?? fallback
    }

    static func integer(
        _ name: String, in request: HTTPRequest, default fallback: Int?,
        range: ClosedRange<Int>
    ) throws -> Int? {
        guard let text = request.parameter(name) else { return fallback }
        // Digits only: no sign, no spaces, and short enough not to overflow.
        guard !text.isEmpty, text.count <= 12, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = Int(text) else { throw EndpointFailure.invalid(name) }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func page<T>(_ items: [T], offset: Int, count: Int) -> [T] {
        guard offset < items.count, count > 0 else { return [] }
        return Array(items[offset..<min(offset + count, items.count)])
    }

    // MARK: - Ordering and matching

    typealias Summary = SQLiteLibraryStore.AlbumSummary

    /// Every ordering ends on the album's id, so that two albums that tie
    /// keep the same order from one page request to the next.
    static func byTitle(_ a: Summary, _ b: Summary) -> Bool {
        let order = a.key.title.localizedStandardCompare(b.key.title)
        return order != .orderedSame ? order == .orderedAscending
            : a.key.stableID < b.key.stableID
    }

    static func byArtist(_ a: Summary, _ b: Summary) -> Bool {
        let order = Artist.stripArticle(a.key.albumArtist)
            .localizedStandardCompare(Artist.stripArticle(b.key.albumArtist))
        return order != .orderedSame ? order == .orderedAscending : byYear(a, b)
    }

    static func byYear(_ a: Summary, _ b: Summary) -> Bool {
        let (ay, by) = (a.key.year ?? 0, b.key.year ?? 0)
        return ay != by ? ay < by : byTitle(a, b)
    }

    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func terms(in query: String) -> [String] {
        fold(query).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Every term appears somewhere in the text, ignoring case and accents.
    static func matches(_ text: String, _ terms: [String]) -> Bool {
        let folded = fold(text)
        return terms.allSatisfy(folded.contains)
    }
}
