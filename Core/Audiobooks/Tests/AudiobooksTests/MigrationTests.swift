import Foundation
import Testing
import GRDB
@testable import Audiobooks

/// Migrations against a database with something in it.
///
/// The only migration test until now applied them to an empty file and listed
/// the tables that appeared. That proves the SQL parses. It does not prove the
/// thing a migration has to be right about: that the data already on somebody's
/// phone is still there afterwards.
///
/// This is the one class of bug with no recovery. A wrong query shows the wrong
/// screen and is fixed by the next launch; a migration that drops a table takes
/// bookmarks, listening history and every position recorded offline, and the
/// backup is a week old.
@Suite("Migrating a populated database")
struct MigrationTests {

    /// A database at v1, with rows in the tables a listener would care about.
    ///
    /// Written through raw SQL rather than the stores, deliberately: the stores
    /// describe the schema as it is *now*, so using them would seed a v1
    /// database with v2 assumptions and quietly test nothing.
    private func v1Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()

        let migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v1_initial")

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO server (machine_identifier, name, last_connection_was_relay)
                VALUES ('srv', 'test', 0)
                """)
            try db.execute(sql: """
                INSERT INTO library_section (id, server_id, section_key, title)
                VALUES ('srv:2', 'srv', '2', 'Audiobooks')
                """)
            try db.execute(sql: """
                INSERT INTO book (rating_key, library_section_id, title, cached_at)
                VALUES ('900', 'srv:2', 'A Hat Full of Sky', ?)
                """, arguments: [Date()])

            // The rows that cannot be refetched from Plex.
            try db.execute(sql: """
                INSERT INTO bookmark (id, book_rating_key, absolute_ms, label, created_at, revision, dirty)
                VALUES ('b1', '900', 1234, 'The good bit', ?, 1, 1)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO progress (book_rating_key, absolute_ms, changed_at, dirty)
                VALUES ('900', 5678, ?, 1)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO listening_session
                    (id, book_rating_key, started_at, ended_at, start_ms, end_ms, rate, revision, dirty)
                VALUES ('s1', '900', ?, ?, 0, 60000, 1.0, 1, 1)
                """, arguments: [Date(), Date()])
        }

        return queue
    }

    @Test("A populated v1 database migrates without losing user data")
    func userDataSurvives() throws {
        let queue = try v1Database()

        let migrator = Schema.migrator()
        try migrator.migrate(queue)

        try queue.read { db in
            let bookmark = try Row.fetchOne(db, sql: "SELECT * FROM bookmark WHERE id = 'b1'")
            #expect(bookmark?["absolute_ms"] as Int? == 1234)
            #expect(bookmark?["label"] as String? == "The good bit")

            let progress = try Row.fetchOne(
                db, sql: "SELECT * FROM progress WHERE book_rating_key = '900'"
            )
            #expect(progress?["absolute_ms"] as Int? == 5678)

            let sessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listening_session")
            #expect(sessions == 1)
        }
    }

    /// The dirty flags are what an unsynced position is *made of*. A migration
    /// that rebuilt a table and dropped them would leave the rows in place and
    /// the work already done invisible to the next sync.
    @Test("Unsynced work is still marked unsynced afterwards")
    func dirtyFlagsSurvive() throws {
        let queue = try v1Database()

        let migrator = Schema.migrator()
        try migrator.migrate(queue)

        try queue.read { db in
            let dirtyBookmarks = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM bookmark WHERE dirty = 1"
            )
            let dirtyProgress = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM progress WHERE dirty = 1"
            )
            #expect(dirtyBookmarks == 1)
            #expect(dirtyProgress == 1)
        }
    }

    @Test("The cached library survives too, so nothing needs refetching")
    func cachedLibrarySurvives() throws {
        let queue = try v1Database()

        let migrator = Schema.migrator()
        try migrator.migrate(queue)

        try queue.read { db in
            let title = try String.fetchOne(
                db, sql: "SELECT title FROM book WHERE rating_key = '900'"
            )
            #expect(title == "A Hat Full of Sky")
        }
    }

    /// What v2 was for.
    @Test("The new tables arrive on an existing database, not only a fresh one")
    func newTablesAppear() throws {
        let queue = try v1Database()

        let migrator = Schema.migrator()
        try migrator.migrate(queue)

        try queue.read { db in
            let hasCollections = try db.tableExists("plex_collection")
            let hasItems = try db.tableExists("plex_collection_item")
            #expect(hasCollections)
            #expect(hasItems)
        }
    }

    /// v4 drops two tables. Dropping is the one migration that can lose
    /// something, so this is the case worth being sure about: the tables go and
    /// nothing else does.
    @Test("Dropping the unused collection tables leaves the rest alone")
    func droppedTablesTakeNothingWithThem() throws {
        let queue = try v1Database()

        // A row in each, which no shipping code has ever written — if the drop
        // took a foreign key with it, the books would go too.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO collection (id, name, position, revision, dirty)
                VALUES ('c1', 'Bedtime', 0, 1, 1)
                """)
            try db.execute(sql: """
                INSERT INTO collection_item (collection_id, book_rating_key, position)
                VALUES ('c1', '900', 0)
                """)
        }

        let migrator = Schema.migrator()
        try migrator.migrate(queue)

        try queue.read { db in
            let hasCollection = try db.tableExists("collection")
            let hasItems = try db.tableExists("collection_item")
            #expect(!hasCollection)
            #expect(!hasItems)

            // The book the dropped row pointed at is still here.
            let title = try String.fetchOne(
                db, sql: "SELECT title FROM book WHERE rating_key = '900'"
            )
            #expect(title == "A Hat Full of Sky")

            let bookmarks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark")
            #expect(bookmarks == 1)
        }
    }

    /// Migrating an already-current database is what every launch after the
    /// first one does.
    @Test("Running the migrations twice changes nothing")
    func migratingTwiceIsSafe() throws {
        let queue = try v1Database()

        let migrator = Schema.migrator()
        try migrator.migrate(queue)
        try migrator.migrate(queue)

        try queue.read { db in
            let bookmarks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark")
            #expect(bookmarks == 1)
        }
    }

    /// `currentVersion` is compared against the applied migrations elsewhere, so
    /// a version that does not match the last registered migration is a
    /// mismatch nothing else would notice.
    @Test("The declared current version is the one actually applied")
    func currentVersionIsApplied() throws {
        let queue = try DatabaseQueue()
        let migrator = Schema.migrator()
        try migrator.migrate(queue)

        let applied = try queue.read { db in
            try migrator.appliedMigrations(db)
        }
        #expect(applied.last == Schema.currentVersion)
    }
    // MARK: - v9, the backfill

    /// A database at v8: books cached, and no identities, which is exactly what
    /// v7 left on every device that already had a library.
    private func v8Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()

        let migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v8_cloud_progress_inbox")

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO server (machine_identifier, name, last_connection_was_relay)
                VALUES ('e45929718f', 'test', 0)
                """)
            try db.execute(sql: """
                INSERT INTO library_section (id, server_id, section_key, title)
                VALUES ('e45929718f:2', 'e45929718f', '2', 'Audiobooks')
                """)
            try db.execute(sql: """
                INSERT INTO book (rating_key, library_section_id, title, cached_at)
                VALUES ('122344', 'e45929718f:2', 'A Book', ?),
                       ('122345', 'e45929718f:2', 'Another Book', ?)
                """, arguments: [Date(), Date()])

            // One book that has been cached since, so it already knows what it
            // is. The backfill must not overwrite that with the weaker form.
            try db.execute(sql: """
                UPDATE book SET identity_key = 'spokenmeta:audible:us:B08G9PRS1K'
                WHERE rating_key = '122345'
                """)
        }

        return queue
    }

    /// The failure this migration exists to fix: `identity_key` null on every
    /// book already cached, so nothing pushed and nothing resolved.
    @Test("v9 gives an existing book a per-server identity")
    func backfillsIdentity() throws {
        let queue = try v8Database()

        let migrator = Schema.migrator()
        try migrator.migrate(queue)

        let key = try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT identity_key FROM book WHERE rating_key = '122344'"
            )
        }
        #expect(key == "plex:e45929718f:122344")
    }

    /// The machine identifier comes from the section id, and getting that split
    /// wrong is the failure mode with no symptom: a well-formed key that no
    /// other device agrees with, so the book simply stops syncing.
    @Test("The server part is the section id before the colon, not the whole of it")
    func serverPartIsCorrect() throws {
        let queue = try v8Database()

        let migrator = Schema.migrator()
        try migrator.migrate(queue)

        let key = try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT identity_key FROM book WHERE rating_key = '122344'"
            )
        }

        // Not the section id whole, and not the section key.
        #expect(key?.contains("e45929718f:2") == false)
        #expect(key?.hasPrefix("plex:e45929718f:") == true)
    }

    /// A provider identity is stronger than anything this migration can work
    /// out, so a book that already has one keeps it.
    @Test("A book that already knows its identity is left alone")
    func doesNotOverwriteAKnownIdentity() throws {
        let queue = try v8Database()

        let migrator = Schema.migrator()
        try migrator.migrate(queue)

        let key = try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT identity_key FROM book WHERE rating_key = '122345'"
            )
        }
        #expect(key == "spokenmeta:audible:us:B08G9PRS1K")
    }

    /// Two devices on one server produce the same key, which is what makes the
    /// backfill worth doing at all: it restores syncing between them without
    /// waiting for either to refresh its library.
    @Test("The same book on the same server backfills identically on two devices")
    func twoDevicesAgree() throws {
        let first = try v8Database()
        let second = try v8Database()

        let migrator = Schema.migrator()
        try migrator.migrate(first)
        try migrator.migrate(second)

        func key(_ queue: DatabaseQueue) throws -> String? {
            try queue.read { db in
                try String.fetchOne(
                    db, sql: "SELECT identity_key FROM book WHERE rating_key = '122344'"
                )
            }
        }

        let a = try key(first)
        let b = try key(second)
        #expect(a == b)
        #expect(a != nil)
    }

}
