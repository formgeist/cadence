import Foundation
import CadenceCore

/// Another Mac's library, as the `LibraryStore` the Mac app is built on.
///
/// The Mac app loads its whole library at once and works on it in memory:
/// albums, artists and genres are all worked out from `allTracks()`. So
/// rather than teach every screen to page through a server, this store reads
/// every song once, a page at a time through an empty `search3`, and answers
/// the rest from that.
///
/// **Read-only.** The server cannot change the library, so every write
/// throws `RemoteError.readOnly` without asking it. The app hides the
/// controls that would make one; this is the backstop.
///
/// **Offline.** Each read goes to the network first. When the Mac is asleep
/// or the network is down, the read is answered from the client's metadata
/// cache instead, so the app still opens on the library it last saw. Any
/// other failure, such as a revoked key, is thrown: an old answer would hide
/// something only the user can fix. With nothing cached, the network error
/// is thrown, since that is what the user needs to hear.
///
/// **What is not shared.** Playlist folders, catalogs and custom artist
/// images are kept on the Mac and are not part of the protocol, so they come
/// back empty, as they do from a store that keeps none. Library size is not
/// shared either and reads as zero.
public actor RemoteLibraryStore: LibraryStore {

    /// The server's largest page.
    public static let pageSize = 500

    private let client: RemoteLibraryClient
    private let pageSize: Int
    /// The last full listing, for the reads that are worked out from it.
    private var snapshot: [Track]?
    private var byID: [Track.ID: Track] = [:]

    /// - Parameter pageSize: Songs per request. Smaller only in tests, so a
    ///   small library can span several pages.
    public init(client: RemoteLibraryClient, pageSize: Int = RemoteLibraryStore.pageSize) {
        self.client = client
        self.pageSize = max(1, pageSize)
    }

    // MARK: - Tracks

    public func allTracks() async throws -> [Track] {
        let tracks = try await Self.fallingBack { source in
            try await self.listing(from: source)
        }
        snapshot = tracks
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tracks
    }

    private func listing(from source: RemoteReadSource) async throws -> [Track] {
        var tracks: [Track] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await client.search("", artistCount: 0, albumCount: 0,
                                               songCount: pageSize, songOffset: offset,
                                               source: source).song
            tracks += page.compactMap { Track(remote: $0) }
            // A short page is the last one. Counting raw songs, not mapped
            // tracks, so a song with an id this client skips cannot end the
            // listing early.
            guard page.count == pageSize else { return tracks }
            offset += page.count
        }
    }

    /// The listing, read once and reused.
    private func tracks() async throws -> [Track] {
        if let snapshot { return snapshot }
        return try await allTracks()
    }

    public func tracks(matching query: String) async throws -> [Track] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let songs = try await client.search(query, artistCount: 0, albumCount: 0,
                                            songCount: Self.pageSize).song
        // The listing's copy where there is one: it is the same track, and
        // keeping one copy keeps selection and the queue consistent.
        return songs.compactMap { song in
            RemoteIDs.uuid(song.id, prefix: "tr-").flatMap { byID[$0] } ?? Track(remote: song)
        }
    }

    // MARK: - Albums and artists

    public func albums() async throws -> [Album] {
        Album.grouped(from: try await tracks())
    }

    public func album(for key: Album.Key) async throws -> Album? {
        let tracks = try await tracks().filter { $0.albumKey == key }
        return Album.grouped(from: tracks).first
    }

    public func albums(byArtist name: String) async throws -> [Album] {
        Album.grouped(from: try await tracks().filter { $0.albumArtist == name })
            .sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    }

    /// Worked out the way the Mac's own store works them out: one artist per
    /// album artist, with distinct albums, track count and codecs.
    public func artists() async throws -> [Artist] {
        let groups = Dictionary(grouping: try await tracks(), by: \.albumArtist)
        return groups.map { name, tracks in
            Artist(name: name,
                   albumCount: Set(tracks.map { AlbumIdentity(title: $0.albumTitle, year: $0.year) }).count,
                   trackCount: tracks.count,
                   formats: Set(tracks.map(\.format.codec.name)).sorted())
        }
        .sorted {
            Artist.stripArticle($0.name)
                .localizedStandardCompare(Artist.stripArticle($1.name)) == .orderedAscending
        }
    }

    private struct AlbumIdentity: Hashable {
        var title: String
        var year: Int?
    }

    // MARK: - Playlists and likes

    /// Every playlist with its tracks. The list answer carries no songs, so
    /// each playlist is fetched in turn: one at a time, so a large sidebar
    /// does not open dozens of connections to the Mac at once.
    public func playlists() async throws -> [Playlist] {
        try await Self.fallingBack { source in
            var playlists: [Playlist] = []
            for summary in try await self.client.playlists(source: source) {
                try Task.checkCancellation()
                let full = try await self.client.playlist(id: summary.id, source: source)
                if let playlist = Playlist(remote: full) { playlists.append(playlist) }
            }
            return playlists
        }
    }

    public func likedTrackIDs() async throws -> [Track.ID] {
        try await Self.fallingBack { source in
            try await self.client.starred(source: source).song
                .compactMap { RemoteIDs.uuid($0.id, prefix: "tr-") }
        }
    }

    public func playlistFolders() async throws -> [PlaylistFolder] { [] }

    public func librarySize() async throws -> Int64 { 0 }

    // MARK: - Reading through the cache

    /// Runs `body` against the network, and again against the cache when
    /// the Mac cannot be reached.
    static func fallingBack<Value: Sendable>(
        _ body: @Sendable (RemoteReadSource) async throws -> Value
    ) async throws -> Value {
        do {
            return try await body(.network)
        } catch let error as RemoteError where error.isAbsence {
            do {
                return try await body(.cache)
            } catch RemoteError.notCached {
                throw error
            }
        }
    }

    // MARK: - Writes

    public func createPlaylist(named name: String) async throws -> Playlist { throw RemoteError.readOnly }
    public func addTracks(_ trackIDs: [Track.ID], to playlistID: Playlist.ID) async throws {
        throw RemoteError.readOnly
    }
    public func removeTracks(atOffsets offsets: IndexSet, from playlistID: Playlist.ID) async throws {
        throw RemoteError.readOnly
    }
    public func moveTracks(fromOffsets source: IndexSet, toOffset destination: Int,
                           in playlistID: Playlist.ID) async throws {
        throw RemoteError.readOnly
    }
    public func renamePlaylist(_ id: Playlist.ID, to name: String) async throws { throw RemoteError.readOnly }
    public func deletePlaylist(_ id: Playlist.ID) async throws { throw RemoteError.readOnly }
    public func setPlaylistImage(_ id: Artwork.ID?, forPlaylist playlistID: Playlist.ID) async throws {
        throw RemoteError.readOnly
    }
    public func createPlaylistFolder(named name: String) async throws -> PlaylistFolder {
        throw RemoteError.readOnly
    }
    public func renamePlaylistFolder(_ id: PlaylistFolder.ID, to name: String) async throws {
        throw RemoteError.readOnly
    }
    public func deletePlaylistFolder(_ id: PlaylistFolder.ID) async throws { throw RemoteError.readOnly }
    public func movePlaylist(_ id: Playlist.ID, toFolder folderID: PlaylistFolder.ID?) async throws {
        throw RemoteError.readOnly
    }
    public func setPlaylistOrder(_ ids: [Playlist.ID]) async throws { throw RemoteError.readOnly }
    public func upsert(_ tracks: [Track]) async throws { throw RemoteError.readOnly }
    public func remove(trackIDs: [Track.ID]) async throws { throw RemoteError.readOnly }
    public func setCustomArtistImage(_ id: Artwork.ID?, forArtist name: String) async throws {
        throw RemoteError.readOnly
    }
    public func saveCatalog(_ catalog: Catalog) async throws { throw RemoteError.readOnly }
    public func deleteCatalog(_ id: Catalog.ID) async throws { throw RemoteError.readOnly }
    public func setLiked(_ liked: Bool, trackIDs: [Track.ID]) async throws { throw RemoteError.readOnly }
}

extension RemoteError {
    /// The Mac is not there to ask, as opposed to answering no. These are
    /// the failures a cached answer may stand in for.
    var isAbsence: Bool {
        switch self {
        case .offline, .unreachable, .busy: true
        default: false
        }
    }
}
