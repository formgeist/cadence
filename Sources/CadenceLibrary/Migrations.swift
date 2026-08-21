import Foundation
import GRDB

/// Schema, search index, and the connection pragmas.
///
/// The FTS5 table is standalone rather than an external-content table: its
/// columns are denormalised copies of the ones worth searching, and `upsert`
/// writes both sides explicitly. Triggers would keep them in sync for free, but
/// they hide the write, and an import that silently fails to index is the kind
/// of bug that only shows up as "search returns nothing".
///
/// Each search row is stored under the same rowid as the track it indexes. FTS5
/// cannot index an `UNINDEXED` column, so removing a stale entry by `trackID`
/// scans the entire search table — which made import quadratic: 30,000 tracks
/// spent 72 of their 75 seconds deleting. By rowid it is a direct lookup.
public enum Migrations {

    /// WAL so a long import doesn't block reads, and a busy timeout so a
    /// concurrent reader waits instead of failing.
    public static func configuration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        config.busyMode = .timeout(5)
        return config
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-tracks") { db in
            try db.create(table: "track") { t in
                t.primaryKey("id", .text)
                // The file path is the natural key for re-import: scanning the
                // same folder twice must update rows, not duplicate them.
                t.column("url", .text).notNull().unique().indexed()
                t.column("bookmark", .blob)

                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("albumArtist", .text).notNull()
                t.column("albumTitle", .text).notNull()
                t.column("composer", .text)
                t.column("genre", .text)
                t.column("year", .integer)

                t.column("trackNumber", .integer)
                t.column("trackCount", .integer)
                t.column("discNumber", .integer)
                t.column("discCount", .integer)

                t.column("duration", .double).notNull()
                t.column("codec", .text).notNull()
                t.column("sampleRate", .double).notNull()
                t.column("bitDepth", .integer)
                t.column("channelCount", .integer).notNull()

                t.column("artworkID", .text)
                t.column("replayGainTrack", .double)
                t.column("replayGainTrackPeak", .double)
                t.column("replayGainAlbum", .double)
                t.column("replayGainAlbumPeak", .double)

                t.column("isCompilation", .boolean).notNull().defaults(to: false)
                t.column("dateAdded", .datetime).notNull()
                t.column("fingerprint", .text)
                t.column("fileSize", .integer).notNull().defaults(to: 0)
            }

            // Album identity is (albumArtist, title, year) — see PLAN.md §7.
            // Grouping and the album screen both hit this.
            try db.create(
                index: "track_on_album",
                on: "track",
                columns: ["albumArtist", "albumTitle", "year"])

            try db.create(index: "track_on_albumArtist", on: "track", columns: ["albumArtist"])
        }

        migrator.registerMigration("v1-search") { db in
            try db.create(virtualTable: "trackSearch", using: FTS5()) { t in
                // Not indexed: carried so a hit can be resolved to a row
                // without a join back through rowid bookkeeping.
                t.column("trackID").notIndexed()
                t.column("title")
                t.column("artist")
                t.column("albumArtist")
                t.column("albumTitle")
                t.column("composer")
                // Diacritics folded, so searching "Halvard As" finds "Halvard Ås".
                t.tokenizer = .unicode61(diacritics: .remove)
            }
        }

        migrator.registerMigration("v1-playlists") { db in
            try db.create(table: "playlist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "playlistItem") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("playlistID", .text)
                    .notNull()
                    .references("playlist", onDelete: .cascade)
                t.column("trackID", .text)
                    .notNull()
                    .references("track", onDelete: .cascade)
                t.column("position", .integer).notNull()
            }

            try db.create(
                index: "playlistItem_on_playlist",
                on: "playlistItem",
                columns: ["playlistID", "position"])
        }

        // Existing databases indexed rows under arbitrary rowids, so the
        // search table is rebuilt once against the new scheme.
        migrator.registerMigration("v2-search-by-rowid") { db in
            try db.execute(sql: "DELETE FROM trackSearch")
            try db.execute(sql: """
                INSERT INTO trackSearch
                    (rowid, trackID, title, artist, albumArtist, albumTitle, composer)
                SELECT rowid, id, title, artist, albumArtist, albumTitle,
                       IFNULL(composer, '')
                FROM track
                """)
        }

        return migrator
    }
}
