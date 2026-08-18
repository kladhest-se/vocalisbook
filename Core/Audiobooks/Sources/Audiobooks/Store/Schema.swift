import Foundation
import GRDB

/// The schema, as an ordered list of migrations.
///
/// Migrations are append-only and never edited once released — a released
/// migration has already run on someone's device and rewriting it produces two
/// databases claiming the same version. Fix a mistake with a new migration.
///
/// Column names are snake_case because this file gets opened in `sqlite3` more
/// often than anyone expects when something looks wrong on the server side.
///
/// Foreign keys are declared as an explicit column plus `.references(...)`
/// rather than `belongsTo`, which derives a column name of its own. The records
/// map every column by hand through CodingKeys, so a derived name is a name
/// nothing reads — `tests/schema.sh` rejects `belongsTo` outright for that
/// reason, having first been written to guess at it and found the guess wrong.
public enum Schema {

    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        registerV4(&migrator)
        registerV5(&migrator)
        registerV6(&migrator)
        registerV7(&migrator)
        registerV8(&migrator)
        registerV9(&migrator)
        return migrator
    }

    /// Current version, for logging and for the tvOS cache-validity check.
    public static let currentVersion = "v9_backfill_identity"

    private static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial") { db in

            // MARK: Server and library

            try db.create(table: "server") { t in
                t.primaryKey("machine_identifier", .text)
                t.column("name", .text).notNull()
                t.column("last_connected_uri", .text)
                t.column("last_connected_at", .datetime)
                t.column("last_connection_was_relay", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "library_section") { t in
                t.primaryKey("id", .text)
                t.column("server_id", .text).notNull()
                    .references("server", column: "machine_identifier", onDelete: .cascade)
                t.column("section_key", .text).notNull()
                t.column("title", .text).notNull()
                t.column("last_synced_at", .datetime)
                t.uniqueKey(["server_id", "section_key"])
            }

            // MARK: Cached Plex metadata
            //
            // Everything in this block is a mirror of the server and is safe to
            // drop and refetch. It exists so the library is browsable offline
            // and so scrolling does not hit the network.

            try db.create(table: "book") { t in
                t.primaryKey("rating_key", .text)
                t.column("library_section_id", .text).notNull()
                    .references("library_section", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("title_sort", .text)
                t.column("author", .text)
                t.column("author_rating_key", .text)
                t.column("narrator", .text)
                t.column("summary", .text)
                t.column("year", .integer)
                t.column("thumb", .text)
                t.column("track_count", .integer)
                // Summed from tracks, never taken from the album — Plex's
                // album-level duration is frequently absent or wrong.
                t.column("duration_ms", .integer)
                t.column("added_at", .datetime)
                t.column("plex_updated_at", .datetime)
                t.column("cached_at", .datetime).notNull()
            }
            try db.create(index: "book_by_section_title", on: "book",
                          columns: ["library_section_id", "title_sort"])
            try db.create(index: "book_by_author", on: "book", columns: ["author"])

            try db.create(table: "track") { t in
                t.primaryKey("rating_key", .text)
                t.column("book_rating_key", .text).notNull()
                    .references("book", column: "rating_key", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("duration_ms", .integer).notNull()
                // Absolute offset of this track within the book. Denormalised
                // so a timeline can be rebuilt with one query instead of a
                // running sum in Swift on every load.
                t.column("start_ms", .integer).notNull()
                t.column("plex_key", .text).notNull()
                t.column("part_id", .text).notNull()
                t.column("part_key", .text).notNull()
                // part_id + plex updatedAt. Any artefact derived from the file
                // — the download, the parsed chapters — is keyed by this and
                // invalidated when it changes.
                t.column("part_cache_key", .text).notNull()
                t.column("container", .text)
            }
            try db.create(index: "track_by_book_idx", on: "track",
                          columns: ["book_rating_key", "idx"])

            try db.create(table: "chapter") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("book_rating_key", .text).notNull()
                    .references("book", column: "rating_key", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("start_ms", .integer).notNull()
                t.column("end_ms", .integer).notNull()
                // plexMetadata | embeddedInFile | trackBoundary. Stored so a
                // list built from a weaker source can be upgraded later without
                // reparsing everything.
                t.column("source", .text).notNull()
                t.uniqueKey(["book_rating_key", "idx"])
            }

            // MARK: User data
            //
            // Everything below is authoritative locally and syncs via CloudKit.
            // Every table carries `revision` and `dirty` from the outset, even
            // where nothing reads them yet — adding them later would mean a
            // migration on a live database for no reason.

            try db.create(table: "progress") { t in
                t.primaryKey("book_rating_key", .text)
                t.column("absolute_ms", .integer).notNull()
                t.column("changed_at", .datetime).notNull()
                // What we last successfully pushed to Plex, and when. The pair
                // is how "I changed this" is told apart from "I merely read
                // this" at reconnect.
                t.column("synced_offset_ms", .integer)
                t.column("synced_at", .datetime)
                t.column("finished_at", .datetime)
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("dirty", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "bookmark") { t in
                t.primaryKey("id", .text)
                t.column("book_rating_key", .text).notNull()
                t.column("absolute_ms", .integer).notNull()
                t.column("label", .text)
                t.column("created_at", .datetime).notNull()
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("dirty", .boolean).notNull().defaults(to: false)
                // Soft delete. CloudKit needs a tombstone to propagate a
                // deletion; a hard DELETE would resurrect the row from any
                // device that had not synced yet.
                t.column("deleted_at", .datetime)
            }
            try db.create(index: "bookmark_by_book", on: "bookmark",
                          columns: ["book_rating_key", "absolute_ms"])

            try db.create(table: "book_settings") { t in
                t.primaryKey("book_rating_key", .text)
                t.column("rate", .double)
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("dirty", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "listening_session") { t in
                t.primaryKey("id", .text)
                t.column("book_rating_key", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
                t.column("start_ms", .integer).notNull()
                t.column("end_ms", .integer)
                t.column("rate", .double)
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("dirty", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "session_by_started", on: "listening_session",
                          columns: ["started_at"])

            try db.create(table: "collection") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("dirty", .boolean).notNull().defaults(to: false)
                t.column("deleted_at", .datetime)
            }

            try db.create(table: "collection_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("collection_id", .text).notNull()
                    .references("collection", onDelete: .cascade)
                t.column("book_rating_key", .text).notNull()
                // Insertion order drives "up next in series" on the home screen.
                t.column("position", .integer).notNull()
                t.uniqueKey(["collection_id", "book_rating_key"])
            }

            // MARK: Sync and downloads

            try db.create(table: "outbox") { t in
                t.primaryKey("id", .text)
                t.column("book_rating_key", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("absolute_ms", .integer).notNull()
                t.column("recorded_at", .datetime).notNull()
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
                // Coalescing. One pending row per book per kind, so a two-hour
                // offline session leaves one entry rather than seven hundred.
                t.uniqueKey(["book_rating_key", "kind"])
            }

            try db.create(table: "download") { t in
                t.primaryKey("part_cache_key", .text)
                t.column("book_rating_key", .text).notNull()
                t.column("track_rating_key", .text).notNull()
                t.column("state", .text).notNull()
                t.column("bytes_total", .integer)
                t.column("bytes_done", .integer).notNull().defaults(to: 0)
                // Relative to Application Support. Absolute paths break when
                // the container identifier changes between builds.
                t.column("relative_path", .text)
                t.column("completed_at", .datetime)
                t.column("last_error", .text)
            }
            try db.create(index: "download_by_book", on: "download",
                          columns: ["book_rating_key"])
        }
    }

    /// Plex's own collections, cached like the rest of the library.
    ///
    /// A new migration rather than an edit to v1. v1 has run on real devices, and
    /// rewriting it would leave two databases claiming the same version with
    /// different shapes and nothing able to tell them apart.
    ///
    /// Distinct from the `collection` table above: that one is for collections a
    /// listener makes, which sync via CloudKit because Plex has no API for them.
    /// These come from the server and are cache, droppable and refetchable.
    private static func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_plex_collections") { db in
            try db.create(table: "plex_collection") { t in
                t.primaryKey("rating_key", .text)
                t.column("library_section_id", .text).notNull()
                    .references("library_section", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("title_sort", .text)
                t.column("child_count", .integer)
                t.column("thumb", .text)
                t.column("summary", .text)
                t.column("cached_at", .datetime).notNull()
            }
            try db.create(index: "plex_collection_by_section", on: "plex_collection",
                          columns: ["library_section_id", "title_sort"])

            try db.create(table: "plex_collection_item") { t in
                t.column("collection_rating_key", .text).notNull()
                    .references("plex_collection", column: "rating_key", onDelete: .cascade)
                t.column("book_rating_key", .text).notNull()
                // Plex's own order, which for a series is reading order.
                t.column("position", .integer).notNull()
                t.primaryKey(["collection_rating_key", "book_rating_key"])
            }
        }
    }

    /// Genres, as a table rather than a column.
    ///
    /// A book has several — "Fantasy" and "Humour" and "Adventure" — so a column
    /// would have to hold a list, and a list in a column cannot be grouped or
    /// counted without unpacking every row in the library first.
    ///
    /// No `library_section_id` here: a genre belongs to a book, and the book
    /// already knows its section. Cascading from `book` also means purging the
    /// metadata cache takes the genres with it, which is what should happen —
    /// they are Plex's, not the listener's.
    private static func registerV3(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_genres") { db in
            try db.create(table: "book_genre") { t in
                t.column("book_rating_key", .text).notNull()
                    .references("book", column: "rating_key", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.primaryKey(["book_rating_key", "name"])
            }
            // The query this exists for is "every genre, with a count", which
            // groups by name.
            try db.create(index: "book_genre_by_name", on: "book_genre", columns: ["name"])
        }
    }

    /// Drops the tables for a feature that was never built.
    ///
    /// `collection` and `collection_item` were created in v1 for collections a
    /// listener makes, as opposed to the ones Plex holds. No code has ever
    /// written to them or read from them.
    ///
    /// Dropped rather than left, because they carry `revision`, `dirty` and
    /// `deleted_at` — the shape of a sync path — so the next person to read this
    /// schema would reasonably conclude the feature is half-finished and try to
    /// complete it against a design nobody chose. An empty table that describes
    /// an intention is worse than no table.
    ///
    /// Nothing is lost: they have never held a row, and recreating them is a
    /// migration whenever somebody decides what a custom collection should
    /// actually do.
    ///
    /// Items first — the child table references the parent.
    private static func registerV4(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4_drop_custom_collections") { db in
            try db.drop(table: "collection_item")
            try db.drop(table: "collection")
        }
    }

    /// A second dirty flag on `progress`, for iCloud.
    ///
    /// `dirty` already has an owner: it means "not yet acknowledged by Plex", and
    /// it is cleared when Plex takes the position. Letting iCloud consume the
    /// same flag would mean whichever pushed first marked the row clean and the
    /// other never saw it.
    ///
    /// Defaulted to 1, not 0. Every position this device already knows is
    /// something the other devices probably do not, and a flag that starts clean
    /// would sync nothing until each book was played again. The first push after
    /// upgrading carries the backlog, which is a handful of rows — one per book
    /// ever started — and then it is quiet.
    private static func registerV5(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5_progress_cloud_dirty") { db in
            try db.alter(table: "progress") { t in
                t.add(column: "cloud_dirty", .boolean).notNull().defaults(to: true)
            }
        }
    }

    /// Narrators, co-authors and series, from the tags VocalisMeta writes.
    ///
    /// Plex's music schema has nowhere to put any of them, so that agent
    /// documents where it puts them instead: `Style` is narrators, `Mood` is
    /// authors, and a Mood beginning `Series: ` is a series. This is where they
    /// land once decoded.
    ///
    /// Three tables rather than columns on `book`, for the same reason genres got
    /// one: a book has any number of each, and "the books in this series" is a
    /// query somebody will want.
    ///
    /// All three cascade from `book`, so a re-scan that drops a book takes its
    /// credits with it.
    private static func registerV6(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6_book_credits") { db in
            try db.create(table: "book_narrator") { t in
                t.column("book_rating_key", .text).notNull()
                    .references("book", column: "rating_key", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.primaryKey(["book_rating_key", "name"])
            }

            try db.create(table: "book_author") { t in
                t.column("book_rating_key", .text).notNull()
                    .references("book", column: "rating_key", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.primaryKey(["book_rating_key", "name"])
            }

            try db.create(table: "book_series") { t in
                t.column("book_rating_key", .text).notNull()
                    .references("book", column: "rating_key", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.primaryKey(["book_rating_key", "name"])
            }

            // Each exists to answer "who else, and what else in this series",
            // which groups by name rather than by book.
            try db.create(index: "book_narrator_by_name", on: "book_narrator", columns: ["name"])
            try db.create(index: "book_author_by_name", on: "book_author", columns: ["name"])
            try db.create(index: "book_series_by_name", on: "book_series", columns: ["name"])
        }
    }

    /// Language, edition, sequence, and the book's durable identity.
    ///
    /// Columns rather than tables for the first two: a book has one language and
    /// one edition, and a table for a single optional value is a join for
    /// nothing.
    ///
    /// `book_sequence` is a table because a book can be in several series, each
    /// with its own position — the second half of what `book_series` records.
    ///
    /// `identity_key` is the canonical cross-server identity from the agent's
    /// GUID: `spokenmeta:audible:us:B08G9PRS1K`, or a `plex:<machine>:<key>`
    /// fallback. Stored beside the rating key rather than replacing it, as the
    /// contract requires — the rating key remains the playback address, and the
    /// identity is what travels.
    ///
    /// Nullable, and nothing reads it yet. Cloud records are still keyed by
    /// rating key, and moving them is a migration with a merge step that wants
    /// doing on its own rather than as the tail of this.
    private static func registerV7(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7_book_edition_and_identity") { db in
            try db.alter(table: "book") { t in
                t.add(column: "language", .text)
                t.add(column: "edition", .text)
                t.add(column: "identity_key", .text)
            }

            try db.create(table: "book_sequence") { t in
                t.column("book_rating_key", .text).notNull()
                    .references("book", column: "rating_key", onDelete: .cascade)
                t.column("series", .text).notNull()
                t.column("position", .text).notNull()
                t.primaryKey(["book_rating_key", "series"])
            }

            // "Everything in this series, in order" is the query it exists for.
            try db.create(index: "book_sequence_by_series", on: "book_sequence", columns: ["series"])

            // And "which book is this, really", for the identity work to come.
            try db.create(index: "book_by_identity", on: "book", columns: ["identity_key"])
        }
    }

    /// Somewhere to put a position for a book this device does not have yet.
    ///
    /// This is the problem that makes identity-keyed sync more than a rename.
    /// `progress` is keyed by rating key — a row cannot exist for a book that has
    /// not been cached — while a cloud record is keyed by an identity that means
    /// the same book everywhere. A phone that has synced its library and a
    /// television that has not are the normal case, not an edge one, and dropping
    /// the record loses a position permanently: nothing will send it again,
    /// because the sending device believes it was delivered.
    ///
    /// So it is held here, keyed by identity, and materialised into `progress`
    /// when the matching book is cached. An inbox rather than a second source of
    /// truth: rows leave as soon as they can, and the screens never read it.
    private static func registerV8(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8_cloud_progress_inbox") { db in
            try db.create(table: "cloud_progress") { t in
                t.primaryKey("identity_key", .text)
                t.column("absolute_ms", .integer).notNull()
                t.column("changed_at", .datetime).notNull()
                t.column("finished_at", .datetime)
                t.column("revision", .integer).notNull().defaults(to: 0)
            }
        }
    }

    /// Gives every book already in the database an identity.
    ///
    /// v7 added the column and left it null for everything already cached, and
    /// only a fresh cache of a book fills it. Progress is pushed with
    /// `identity_key IS NOT NULL` and arriving records resolve through it — so
    /// after upgrading, every book anybody owned stopped syncing until the whole
    /// library happened to be refreshed. That is a migration that did half its
    /// job, and it is the reason sync looked flaky rather than broken.
    ///
    /// Backfilled to the per-server form, because that is all this can know: the
    /// provider identity lives in the Plex GUID, which was never stored. A book
    /// gets its real identity the next time it is cached.
    ///
    /// The server's machine identifier is the part of `library_section_id`
    /// before the colon — `srv:2` — which is the same assumption
    /// `LibraryStore.identityKey` makes, in the one other place that builds this
    /// string.
    ///
    /// Two devices pointed at the same server produce the same key here, so this
    /// alone restores syncing between them. Two different servers do not, which
    /// is exactly what the per-server form means.
    private static func registerV9(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9_backfill_identity") { db in
            try db.execute(sql: """
                UPDATE book
                SET identity_key = 'plex:'
                    || substr(library_section_id, 1, instr(library_section_id, ':') - 1)
                    || ':' || rating_key
                WHERE identity_key IS NULL
                  AND instr(library_section_id, ':') > 1
                """)
        }
    }
}
