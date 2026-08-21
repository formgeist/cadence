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
        let tracks = try await allTracks()
        return Self.group(tracks)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
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
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT albumArtist AS name,
                       COUNT(DISTINCT albumTitle || '\u{1}' || IFNULL(year, '')) AS albumCount,
                       COUNT(*) AS trackCount,
                       GROUP_CONCAT(DISTINCT codec) AS codecs
                FROM track
                GROUP BY albumArtist
                """)
        }
        return rows.map { row in
            Artist(
                name: row["name"],
                albumCount: row["albumCount"],
                trackCount: row["trackCount"],
                formats: ((row["codecs"] as String?) ?? "")
                    .split(separator: ",").map(String.init).sorted())
        }
        .sorted {
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

    public func librarySize() async throws -> Int64 {
        try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT IFNULL(SUM(fileSize), 0) FROM track") ?? 0
        }
    }

    // MARK: - Search

    /// Prefix-matched FTS5. Every token gets a `*` so results appear while the
    /// user is still typing, which is the only behaviour that makes a
    /// search-as-you-type field feel like one.
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
                    """, arguments: [pattern]).map(\.track)
            } catch {
                // A malformed pattern is a user typing, not a bug. Returning
                // nothing beats throwing into the search field.
                return []
            }
        }
    }

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

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func group(_ tracks: [Track]) -> [Album] {
        Dictionary(grouping: tracks, by: \.albumKey)
            .map { Album(key: $0.key, tracks: $0.value) }
    }
}
