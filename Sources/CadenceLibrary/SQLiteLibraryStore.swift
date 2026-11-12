import Foundation
import GRDB
import CadenceCore

public enum LibraryStoreError: Error {
    case openFailed(String)
}

/// The real `LibraryStore`. Every query the interface needs, plus the FTS
/// population that search depends on.
public final class SQLiteLibraryStore: LibraryStore, Sendable {

    private let pool: DatabasePool

    /// Opens (and migrates) the database at `url`, creating parent directories.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        pool = try DatabasePool(path: url.path, configuration: Migrations.configuration())
        try Migrations.migrator.migrate(pool)
    }

    /// The default location: `~/Library/Application Support/Cadence/library.sqlite`.
    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent("library.sqlite")
    }

    // MARK: - Reads

    public func allTracks() async throws -> [Track] {
        try await pool.read { db in
            try TrackRecord.fetchAll(db).map(\.track)
        }
    }

    public func albums() async throws -> [Album] {
        Album.grouped(from: try await allTracks())
    }

    public func album(for key: Album.Key) async throws -> Album? {
        let records = try await pool.read { db -> [TrackRecord] in
            // A nil year is a distinct key, not a wildcard: `IS` rather than
            // `=` so an untagged album matches itself instead of nothing.
            try TrackRecord.fetchAll(db, sql: """
                SELECT * FROM track
                WHERE albumArtist = ? AND albumTitle = ? AND year IS ?
                """, arguments: [key.albumArtist, key.title, key.year])
        }
        guard !records.isEmpty else { return nil }
        return Album(key: key, tracks: records.map(\.track))
    }

    public func artists() async throws -> [Artist] {
        // Map to `Artist` inside the read: GRDB's `Row` is not `Sendable`, so
        // returning `[Row]` from the async `read` fails the closure's
        // `T: Sendable` bound (silently, as a `()` inference, on Swift 6.2).
        let artists = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT albumArtist AS name,
                       COUNT(DISTINCT albumTitle || '\u{1}' || IFNULL(year, '')) AS albumCount,
                       COUNT(*) AS trackCount,
                       GROUP_CONCAT(DISTINCT codec) AS codecs
                FROM track
                GROUP BY albumArtist
                """).map { row in
                Artist(
                    name: row["name"],
                    albumCount: row["albumCount"],
                    trackCount: row["trackCount"],
                    formats: ((row["codecs"] as String?) ?? "")
                        .split(separator: ",").map(String.init).sorted())
            }
        }
        return artists.sorted {
            Artist.stripArticle($0.name)
                .localizedStandardCompare(Artist.stripArticle($1.name)) == .orderedAscending
        }
    }

    public func albums(byArtist name: String) async throws -> [Album] {
        let records = try await pool.read { db in
            try TrackRecord.filter(Column("albumArtist") == name).fetchAll(db)
        }
        return Self.group(records.map(\.track))
            .sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    }

    public func playlists() async throws -> [Playlist] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id AS id, p.name AS name, p.folderID AS folderID,
                       p.artworkID AS artworkID, p.updatedAt AS updatedAt,
                       IFNULL(SUM(t.duration), 0) AS duration
                FROM playlist p
                LEFT JOIN playlistItem i ON i.playlistID = p.id
                LEFT JOIN track t ON t.id = i.trackID
                GROUP BY p.id
                ORDER BY p.position, p.name
                """)

            // One query for every playlist's items, rather than one query per
            // playlist: a sidebar with many playlists otherwise round-trips
            // to SQLite once per row just to list its own contents.
            let itemRows = try Row.fetchAll(db, sql: """
                SELECT playlistID, trackID FROM playlistItem ORDER BY playlistID, position
                """)
            var trackIDsByPlaylist: [String: [UUID]] = [:]
            for row in itemRows {
                guard let trackID = UUID(uuidString: row["trackID"] as String) else { continue }
                trackIDsByPlaylist[row["playlistID"] as String, default: []].append(trackID)
            }

            return rows.map { row in
                let id: String = row["id"]
                return Playlist(
                    id: UUID(uuidString: id) ?? UUID(),
                    name: row["name"],
                    trackIDs: trackIDsByPlaylist[id] ?? [],
                    duration: row["duration"],
                    folderID: (row["folderID"] as String?).flatMap(UUID.init),
                    artworkID: row["artworkID"],
                    updatedAt: (row["updatedAt"] as Double?).map(Date.init(timeIntervalSince1970:)))
            }
        }
    }

    /// A new, empty playlist at the end of the sidebar's order.
    ///
    /// Names are not unique — two playlists may legitimately share one — so
    /// the row is identified by its id, which is why the created value is
    /// returned rather than left for the caller to find again by name.
    @discardableResult
    public func createPlaylist(named name: String) async throws -> Playlist {
        let playlist = Playlist(name: name, trackIDs: [], duration: 0, updatedAt: Date())
        try await pool.write { db in
            let position = try Int.fetchOne(
                db, sql: "SELECT IFNULL(MAX(position), -1) + 1 FROM playlist") ?? 0
            try db.execute(
                sql: "INSERT INTO playlist (id, name, position, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [playlist.id.uuidString, name, position,
                            playlist.updatedAt?.timeIntervalSince1970])
        }
        return playlist
    }

    /// Appends to one playlist, leaving every other one alone.
    ///
    /// The insert is `SELECT`-driven so an id whose file has left the library
    /// adds nothing instead of failing the whole batch — a stale selection
    /// dragged in should contribute what still exists.
    public func addTracks(_ trackIDs: [Track.ID], to playlistID: Playlist.ID) async throws {
        guard !trackIDs.isEmpty else { return }
        try await pool.write { db in
            var position = try Int.fetchOne(db, sql: """
                SELECT IFNULL(MAX(position), -1) + 1 FROM playlistItem WHERE playlistID = ?
                """, arguments: [playlistID.uuidString]) ?? 0

            for trackID in trackIDs {
                try db.execute(sql: """
                    INSERT INTO playlistItem (playlistID, trackID, position)
                    SELECT ?, id, ? FROM track WHERE id = ?
                    """, arguments: [playlistID.uuidString, position, trackID.uuidString])
                // Nothing inserted means no such track; leaving the position
                // unspent keeps the run contiguous.
                if db.changesCount > 0 { position += 1 }
            }
            try Self.touch(playlistID, in: db)
        }
    }

    public func removeTracks(
        atOffsets offsets: IndexSet, from playlistID: Playlist.ID
    ) async throws {
        guard !offsets.isEmpty else { return }
        try await pool.write { db in
            let rowIDs = try Self.itemRowIDs(of: playlistID, in: db)
            let doomed = offsets.compactMap { rowIDs.indices.contains($0) ? rowIDs[$0] : nil }
            guard !doomed.isEmpty else { return }

            try db.execute(
                sql: "DELETE FROM playlistItem WHERE rowid IN (\(Self.placeholders(doomed.count)))",
                arguments: StatementArguments(doomed))
            // A `Set` rather than testing `doomed` itself: removing a large
            // selection out of a long playlist would otherwise check every
            // survivor against every doomed row rather than against a hash.
            let doomedSet = Set(doomed)
            try Self.renumber(rowIDs.filter { !doomedSet.contains($0) }, from: rowIDs, in: db)
            try Self.touch(playlistID, in: db)
        }
    }

    public func moveTracks(
        fromOffsets source: IndexSet, toOffset destination: Int, in playlistID: Playlist.ID
    ) async throws {
        guard !source.isEmpty else { return }
        try await pool.write { db in
            // Row ids, not track ids: a playlist may hold the same track twice,
            // and reordering has to move one of them without touching the other.
            let rowIDs = try Self.itemRowIDs(of: playlistID, in: db)
            var moved = rowIDs
            Ordering.move(&moved, fromOffsets: source, toOffset: destination)
            try Self.renumber(moved, from: rowIDs, in: db)
            try Self.touch(playlistID, in: db)
        }
    }

    public func renamePlaylist(_ id: Playlist.ID, to name: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE playlist SET name = ?, updatedAt = ? WHERE id = ?",
                           arguments: [name, Date().timeIntervalSince1970, id.uuidString])
        }
    }

    public func setPlaylistImage(_ id: Artwork.ID?, forPlaylist playlistID: Playlist.ID) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE playlist SET artworkID = ?, updatedAt = ? WHERE id = ?",
                           arguments: [id, Date().timeIntervalSince1970, playlistID.uuidString])
        }
    }

    /// The items go with it: `playlistItem.playlistID` cascades.
    public func deletePlaylist(_ id: Playlist.ID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Playlist folders

    public func playlistFolders() async throws -> [PlaylistFolder] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name FROM playlistFolder ORDER BY position, name
                """)
            .compactMap { row in
                guard let id = UUID(uuidString: row["id"] as String) else { return nil }
                return PlaylistFolder(id: id, name: row["name"])
            }
        }
    }

    /// A new folder at the end of the folder order, the same way a new
    /// playlist goes at the end of the playlists.
    @discardableResult
    public func createPlaylistFolder(named name: String) async throws -> PlaylistFolder {
        let folder = PlaylistFolder(name: name)
        try await pool.write { db in
            let position = try Int.fetchOne(
                db, sql: "SELECT IFNULL(MAX(position), -1) + 1 FROM playlistFolder") ?? 0
            try db.execute(
                sql: "INSERT INTO playlistFolder (id, name, position) VALUES (?, ?, ?)",
                arguments: [folder.id.uuidString, name, position])
        }
        return folder
    }

    public func renamePlaylistFolder(_ id: PlaylistFolder.ID, to name: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE playlistFolder SET name = ? WHERE id = ?",
                           arguments: [name, id.uuidString])
        }
    }

    /// The playlists stay: `playlist.folderID` is `ON DELETE SET NULL`, so
    /// they land back at the top level in the same statement.
    public func deletePlaylistFolder(_ id: PlaylistFolder.ID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM playlistFolder WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    /// A folder id with no folder behind it fails the foreign key rather than
    /// leaving an orphan: the sidebar draws playlists under the folders that
    /// exist, so one filed under nothing would vanish from it.
    public func movePlaylist(
        _ id: Playlist.ID, toFolder folderID: PlaylistFolder.ID?
    ) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE playlist SET folderID = ? WHERE id = ?",
                           arguments: [folderID?.uuidString, id.uuidString])
        }
    }

    public func setPlaylistOrder(_ ids: [Playlist.ID]) async throws {
        try await pool.write { db in
            let named = ids.map(\.uuidString)
            let rest = try String.fetchAll(db, sql: "SELECT id FROM playlist ORDER BY position, name")
                .filter { !named.contains($0) }
            for (position, id) in (named + rest).enumerated() {
                try db.execute(sql: "UPDATE playlist SET position = ? WHERE id = ?",
                               arguments: [position, id])
            }
        }
    }

    public func librarySize() async throws -> Int64 {
        try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT IFNULL(SUM(fileSize), 0) FROM track") ?? 0
        }
    }

    // MARK: - Search

    /// Prefix-matched FTS5. Every token gets a `*` so results appear while the
    /// user is still typing, which is the only behaviour that makes a
    /// search-as-you-type field feel like one.
    ///
    /// Capped at `searchLimit`: the popover shows at most 3 tracks, so
    /// fetching and decoding every matching row for a broad prefix like "a"
    /// is pure waste — see #85.
    public func tracks(matching query: String) async throws -> [Track] {
        let pattern = Self.ftsPattern(for: query)
        guard !pattern.isEmpty else { return [] }

        return try await pool.read { db in
            do {
                return try TrackRecord.fetchAll(db, sql: """
                    SELECT track.* FROM track
                    JOIN trackSearch ON trackSearch.trackID = track.id
                    WHERE trackSearch MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """, arguments: [pattern, Self.searchLimit]).map(\.track)
            } catch {
                // A malformed pattern is a user typing, not a bug. Returning
                // nothing beats throwing into the search field.
                return []
            }
        }
    }

    /// Comfortably above the handful of albums/artists/tracks the popover
    /// actually shows, so a hit that belongs in the top 3 of some category
    /// is never pushed out by rank alone before `AppModel` gets to group it.
    private static let searchLimit = 100

    /// Quotes each token and appends `*`, so punctuation a user types can't
    /// become FTS5 syntax.
    static func ftsPattern(for query: String) -> String {
        query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
    }

    // MARK: - Writes

    /// Writes both the row and its search index, in one transaction. Doing them
    /// separately is how a library ends up searchable for some records and not
    /// others.
    public func upsert(_ tracks: [Track]) async throws {
        try await upsert(tracks.map { ($0, Int64(0)) })
    }

    /// The scanner already knows each file's size; this overload avoids
    /// stat-ing every file a second time.
    public func upsert(_ entries: [(track: Track, fileSize: Int64)]) async throws {
        guard !entries.isEmpty else { return }
        try await pool.write { db in
            for entry in entries {
                let record = TrackRecord(entry.track, fileSize: entry.fileSize)

                // Re-importing the same path must update, not duplicate, and
                // must keep whatever id the existing row already has so
                // playlists pointing at it survive. One lookup gets both the
                // id and the implicit rowid the FTS index is keyed on, so a
                // large import isn't paying for a second round trip per track
                // just to rediscover the rowid `save` already touched.
                let existing = try Row.fetchOne(
                    db, sql: "SELECT rowid, id FROM track WHERE url = ?",
                    arguments: [record.url])

                var toSave = record
                let rowID: Int64
                if let existing {
                    toSave.id = existing["id"]
                    rowID = existing["rowid"]
                    try toSave.save(db)
                } else {
                    try toSave.save(db)
                    rowID = db.lastInsertedRowID
                }
                try Self.indexTrack(toSave, rowID: rowID, in: db, isNew: existing == nil)
            }
        }
    }

    public func remove(urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        let strings = urls.map(\.absoluteString)
        try await pool.write { db in
            let rowIDs = try Int64.fetchAll(
                db,
                sql: "SELECT rowid FROM track WHERE url IN (\(Self.placeholders(strings.count)))",
                arguments: StatementArguments(strings))
            for rowID in rowIDs {
                try db.execute(sql: "DELETE FROM trackSearch WHERE rowid = ?",
                               arguments: [rowID])
            }
            try db.execute(
                sql: "DELETE FROM track WHERE url IN (\(Self.placeholders(strings.count)))",
                arguments: StatementArguments(strings))
        }
    }

    public func remove(trackIDs: [Track.ID]) async throws {
        guard !trackIDs.isEmpty else { return }
        let strings = trackIDs.map(\.uuidString)
        try await pool.write { db in
            let rowIDs = try Int64.fetchAll(
                db,
                sql: "SELECT rowid FROM track WHERE id IN (\(Self.placeholders(strings.count)))",
                arguments: StatementArguments(strings))
            for rowID in rowIDs {
                try db.execute(sql: "DELETE FROM trackSearch WHERE rowid = ?",
                               arguments: [rowID])
            }
            // playlistItem.trackID references track with ON DELETE CASCADE, so
            // this also drops every playlist row that pointed at these tracks.
            try db.execute(
                sql: "DELETE FROM track WHERE id IN (\(Self.placeholders(strings.count)))",
                arguments: StatementArguments(strings))
        }
    }

    /// Every fingerprint already on file, so the scanner can skip files that
    /// have not changed since the last import.
    public func fingerprints() async throws -> [URL: String] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT url, fingerprint FROM track")
            return rows.reduce(into: [URL: String]()) { result, row in
                guard let url = URL(string: row["url"]),
                      let fingerprint: String = row["fingerprint"] else { return }
                result[url] = fingerprint
            }
        }
    }

    /// Every artwork id still spoken for — by a track's cover or by a custom
    /// artist image — so `DiskArtworkStore.prune` knows what is safe to delete.
    /// A user upload that no track references would otherwise look like an
    /// orphan and be swept the next time an import prunes.
    public func referencedArtworkIDs() async throws -> Set<Artwork.ID> {
        try await pool.read { db in
            var ids = try Set(String.fetchAll(
                db, sql: "SELECT DISTINCT artworkID FROM track WHERE artworkID IS NOT NULL"))
            ids.formUnion(try String.fetchAll(
                db, sql: "SELECT DISTINCT artworkID FROM artistImage"))
            ids.formUnion(try String.fetchAll(
                db, sql: "SELECT DISTINCT artworkID FROM playlist WHERE artworkID IS NOT NULL"))
            return ids
        }
    }

    // MARK: - Custom artist images

    public func customArtistImages() async throws -> [String: Artwork.ID] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT artistName, artworkID FROM artistImage")
                .reduce(into: [String: Artwork.ID]()) { result, row in
                    result[row["artistName"]] = row["artworkID"]
                }
        }
    }

    public func setCustomArtistImage(_ id: Artwork.ID?, forArtist name: String) async throws {
        try await pool.write { db in
            if let id {
                try db.execute(sql: """
                    INSERT INTO artistImage (artistName, artworkID) VALUES (?, ?)
                    ON CONFLICT(artistName) DO UPDATE SET artworkID = excluded.artworkID
                    """, arguments: [name, id])
            } else {
                try db.execute(sql: "DELETE FROM artistImage WHERE artistName = ?",
                               arguments: [name])
            }
        }
    }

    public func replacePlaylists(_ playlists: [Playlist]) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM playlist")
            for (index, playlist) in playlists.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO playlist (id, name, position, artworkID, updatedAt)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [playlist.id.uuidString, playlist.name, index, playlist.artworkID,
                                playlist.updatedAt?.timeIntervalSince1970])
                for (position, trackID) in playlist.trackIDs.enumerated() {
                    // Skip ids with no track: a playlist referencing a removed
                    // file should lose the entry, not fail the whole write.
                    try db.execute(sql: """
                        INSERT INTO playlistItem (playlistID, trackID, position)
                        SELECT ?, id, ? FROM track WHERE id = ?
                        """, arguments: [playlist.id.uuidString, position, trackID.uuidString])
                }
            }
        }
    }

    // MARK: - Helpers

    /// Stamps a playlist as changed just now.
    private static func touch(_ playlistID: Playlist.ID, in db: Database) throws {
        try db.execute(sql: "UPDATE playlist SET updatedAt = ? WHERE id = ?",
                       arguments: [Date().timeIntervalSince1970, playlistID.uuidString])
    }

    /// Indexes under the track's own rowid, so replacing an entry is a direct
    /// lookup rather than a scan of the whole search table.
    private static func indexTrack(
        _ record: TrackRecord, rowID: Int64, in db: Database, isNew: Bool
    ) throws {
        // A track that did not exist a moment ago has nothing stale to remove.
        if !isNew {
            try db.execute(
                sql: "DELETE FROM trackSearch WHERE rowid = ?", arguments: [rowID])
        }
        try db.execute(sql: """
            INSERT INTO trackSearch
                (rowid, trackID, title, artist, albumArtist, albumTitle, composer)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                rowID, record.id, record.title, record.artist,
                record.albumArtist, record.albumTitle, record.composer ?? "",
            ])
    }

    /// One playlist's items in playing order, by row id — the handle every
    /// per-item edit needs. A track id would not do: the same track may sit in
    /// a playlist twice, and then an id names two rows.
    private static func itemRowIDs(of playlistID: Playlist.ID, in db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT rowid FROM playlistItem WHERE playlistID = ? ORDER BY position
            """, arguments: [playlistID.uuidString])
    }

    /// Writes 0…n-1 over the given order — but only where a row's position
    /// actually changed against `previous`. A single-track move on a long
    /// playlist only ever displaces the rows strictly between where it left
    /// and where it landed; the rest already hold the position this would
    /// write back unchanged. Rewriting every row anyway was fine as dead
    /// weight while dragging did not work (#25); now that a drop runs this on
    /// every drag, it is not.
    private static func renumber(_ rowIDs: [Int64], from previous: [Int64], in db: Database) throws {
        for (position, rowID) in rowIDs.enumerated()
        where position >= previous.count || previous[position] != rowID {
            try db.execute(sql: "UPDATE playlistItem SET position = ? WHERE rowid = ?",
                           arguments: [position, rowID])
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func group(_ tracks: [Track]) -> [Album] {
        Dictionary(grouping: tracks, by: \.albumKey)
            .map { Album(key: $0.key, tracks: $0.value) }
    }
}

// MARK: - Play history

extension SQLiteLibraryStore: PlayLogStore {
    public func record(_ play: PlayRecord) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO playLog (playedAt, title, artist, albumArtist, albumTitle, albumYear, duration)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [play.playedAt.timeIntervalSince1970, play.title, play.artist,
                                 play.albumArtist, play.albumTitle, play.albumYear, play.duration])
        }
    }

    public func allPlays() async throws -> [PlayRecord] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM playLog ORDER BY playedAt").map { row in
                PlayRecord(title: row["title"], artist: row["artist"],
                           albumArtist: row["albumArtist"], albumTitle: row["albumTitle"],
                           albumYear: row["albumYear"], duration: row["duration"],
                           playedAt: Date(timeIntervalSince1970: row["playedAt"]))
            }
        }
    }
}

// MARK: - Catalogs

extension SQLiteLibraryStore {
    public func catalogs() async throws -> [Catalog] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, definition, createdAt, updatedAt FROM catalog
                ORDER BY createdAt, rowid
                """).compactMap { row -> Catalog? in
                // A row this build cannot read (written by a newer one with a
                // kind of rule this one has never heard of) is skipped rather
                // than failing the whole library load.
                let json: String = row["definition"]
                guard let id = UUID(uuidString: row["id"]),
                      let definition = try? JSONDecoder().decode(
                        Catalog.Definition.self, from: Data(json.utf8))
                else { return nil }
                return Catalog(id: id, name: row["name"], definition: definition,
                               createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                               updatedAt: Date(timeIntervalSince1970: row["updatedAt"]))
            }
        }
    }

    public func saveCatalog(_ catalog: Catalog) async throws {
        let json = String(decoding: try JSONEncoder().encode(catalog.definition), as: UTF8.self)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO catalog (id, name, definition, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                                              definition = excluded.definition,
                                              updatedAt = excluded.updatedAt
                """, arguments: [catalog.id.uuidString, catalog.name, json,
                                 catalog.createdAt.timeIntervalSince1970,
                                 catalog.updatedAt.timeIntervalSince1970])
        }
    }

    public func deleteCatalog(_ id: Catalog.ID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM catalog WHERE id = ?", arguments: [id.uuidString])
        }
    }
}

// MARK: - Liked songs

extension SQLiteLibraryStore {
    /// Newest first; a batch liked in one go shares a timestamp and keeps the
    /// order it was inserted in.
    public func likedTrackIDs() async throws -> [Track.ID] {
        try await pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT trackID FROM likedTrack ORDER BY likedAt DESC, rowid ASC
                """).compactMap { UUID(uuidString: $0) }
        }
    }

    /// `INSERT OR IGNORE` keeps an existing like's original date, and the
    /// `SELECT` from `track` skips ids whose file has left the library, the
    /// way `addTracks` does.
    public func setLiked(_ liked: Bool, trackIDs: [Track.ID]) async throws {
        guard !trackIDs.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try await pool.write { db in
            for trackID in trackIDs {
                if liked {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO likedTrack (trackID, likedAt)
                        SELECT id, ? FROM track WHERE id = ?
                        """, arguments: [now, trackID.uuidString])
                } else {
                    try db.execute(sql: "DELETE FROM likedTrack WHERE trackID = ?",
                                   arguments: [trackID.uuidString])
                }
            }
        }
    }
}

// MARK: - Memories

extension SQLiteLibraryStore: MemoryStore {
    public func memories() async throws -> [Memory] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, albumArtist, albumTitle, albumYear, trackTitle, trackArtist,
                       text, createdAt, updatedAt
                FROM memory ORDER BY createdAt DESC
                """).compactMap { row -> Memory? in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                let album = Album.Key(albumArtist: row["albumArtist"],
                                      title: row["albumTitle"], year: row["albumYear"])
                let subject: Memory.Subject
                if let title: String = row["trackTitle"] {
                    subject = .track(title: title,
                                     artist: (row["trackArtist"] as String?) ?? album.albumArtist,
                                     album: album)
                } else {
                    subject = .album(album)
                }
                return Memory(id: id, subject: subject, text: row["text"],
                              createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                              updatedAt: Date(timeIntervalSince1970: row["updatedAt"]))
            }
        }
    }

    public func saveMemory(_ memory: Memory) async throws {
        let album = memory.subject.albumKey
        // `let`s, not `var`s: the write closure below runs on the pool's
        // queue, and a captured `var` is not allowed across that hop.
        let trackTitle: String?
        let trackArtist: String?
        if case .track(let title, let artist, _) = memory.subject {
            trackTitle = title
            trackArtist = artist
        } else {
            trackTitle = nil
            trackArtist = nil
        }
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO memory (id, albumArtist, albumTitle, albumYear, trackTitle,
                                    trackArtist, text, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET albumArtist = excluded.albumArtist,
                                              albumTitle = excluded.albumTitle,
                                              albumYear = excluded.albumYear,
                                              trackTitle = excluded.trackTitle,
                                              trackArtist = excluded.trackArtist,
                                              text = excluded.text,
                                              updatedAt = excluded.updatedAt
                """, arguments: [memory.id.uuidString, album.albumArtist, album.title,
                                 album.year, trackTitle, trackArtist, memory.text,
                                 memory.createdAt.timeIntervalSince1970,
                                 memory.updatedAt.timeIntervalSince1970])
        }
    }

    public func deleteMemory(_ id: Memory.ID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM memory WHERE id = ?", arguments: [id.uuidString])
        }
    }
}

extension SQLiteLibraryStore: SimilarArtistCache {
    public func cachedSimilarArtists(forKey key: String) async throws
        -> (artists: [ExternalSimilarArtist], fetchedAt: Date)? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT fetchedAt, artists FROM similarArtistCache WHERE artistKey = ?",
                arguments: [key]) else { return nil }
            let json: String = row["artists"]
            let artists = try JSONDecoder().decode([ExternalSimilarArtist].self, from: Data(json.utf8))
            return (artists, Date(timeIntervalSince1970: row["fetchedAt"]))
        }
    }

    public func storeSimilarArtists(_ artists: [ExternalSimilarArtist], forKey key: String,
                                    fetchedAt: Date) async throws {
        let json = String(decoding: try JSONEncoder().encode(artists), as: UTF8.self)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO similarArtistCache (artistKey, fetchedAt, artists) VALUES (?, ?, ?)
                ON CONFLICT(artistKey) DO UPDATE SET fetchedAt = excluded.fetchedAt,
                                                     artists = excluded.artists
                """, arguments: [key, fetchedAt.timeIntervalSince1970, json])
        }
    }

    public func similarArtistCacheCount() async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM similarArtistCache") ?? 0
        }
    }

    public func clearSimilarArtistCache() async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM similarArtistCache")
        }
    }
}
