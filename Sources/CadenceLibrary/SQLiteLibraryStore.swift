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
                SELECT p.id AS id, p.name AS name,
                       IFNULL(SUM(t.duration), 0) AS duration
                FROM playlist p
                LEFT JOIN playlistItem i ON i.playlistID = p.id
                LEFT JOIN track t ON t.id = i.trackID
                GROUP BY p.id
                ORDER BY p.position, p.name
                """)

            return try rows.map { row in
                let id: String = row["id"]
                let trackIDs = try String.fetchAll(db, sql: """
                    SELECT trackID FROM playlistItem
                    WHERE playlistID = ? ORDER BY position
                    """, arguments: [id])
                return Playlist(
                    id: UUID(uuidString: id) ?? UUID(),
                    name: row["name"],
                    trackIDs: trackIDs.compactMap(UUID.init(uuidString:)),
                    duration: row["duration"])
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
        let playlist = Playlist(name: name, trackIDs: [], duration: 0)
        try await pool.write { db in
            let position = try Int.fetchOne(
                db, sql: "SELECT IFNULL(MAX(position), -1) + 1 FROM playlist") ?? 0
            try db.execute(
                sql: "INSERT INTO playlist (id, name, position) VALUES (?, ?, ?)",
                arguments: [playlist.id.uuidString, name, position])
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
        }
    }

    public func renamePlaylist(_ id: Playlist.ID, to name: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE playlist SET name = ? WHERE id = ?",
                           arguments: [name, id.uuidString])
        }
    }

    /// The items go with it: `playlistItem.playlistID` cascades.
    public func deletePlaylist(_ id: Playlist.ID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id.uuidString])
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
                // playlists pointing at it survive.
                let existingID = try String.fetchOne(
                    db, sql: "SELECT id FROM track WHERE url = ?",
                    arguments: [record.url])

                var toSave = record
                if let existingID { toSave.id = existingID }
                try toSave.save(db)
                try Self.indexTrack(toSave, in: db, isNew: existingID == nil)
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

    /// Every artwork id a track still points at, so `DiskArtworkStore.prune`
    /// knows what is safe to delete.
    public func referencedArtworkIDs() async throws -> Set<Artwork.ID> {
        try await pool.read { db in
            try Set(String.fetchAll(
                db, sql: "SELECT DISTINCT artworkID FROM track WHERE artworkID IS NOT NULL"))
        }
    }

    public func replacePlaylists(_ playlists: [Playlist]) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM playlist")
            for (index, playlist) in playlists.enumerated() {
                try db.execute(
                    sql: "INSERT INTO playlist (id, name, position) VALUES (?, ?, ?)",
                    arguments: [playlist.id.uuidString, playlist.name, index])
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

    /// Indexes under the track's own rowid, so replacing an entry is a direct
    /// lookup rather than a scan of the whole search table.
    private static func indexTrack(
        _ record: TrackRecord, in db: Database, isNew: Bool
    ) throws {
        guard let rowID = try Int64.fetchOne(
            db, sql: "SELECT rowid FROM track WHERE url = ?",
            arguments: [record.url]) else { return }

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
