import Foundation
import Testing
import GRDB
@testable import Audiobooks
@testable import PlexKit

/// Removing everything cached on a device.
///
/// Tested carefully because it is the one destructive path here that can lose
/// something: the library comes back from Plex and the listening state from
/// iCloud, but a purge that deletes the wrong table takes something neither can
/// return — and it would look like it worked.
@Suite("Purging local data")
struct PurgeTests {

    private func seeded() throws -> (AudiobookDatabase, LibraryStore, SyncStore, DownloadStore) {
        let db = try AudiobookDatabase.inMemory()

        try db.writer.write { conn in
            let server = ServerRecord(
                machineIdentifier: "srv", name: "test",
                lastConnectedURI: "http://example", lastConnectedAt: Date(),
                lastConnectionWasRelay: false
            )
            try server.insert(conn)
            let section = LibrarySectionRecord(
                id: "srv:2", serverID: "srv", sectionKey: "2",
                title: "Audiobooks", lastSyncedAt: Date()
            )
            try section.insert(conn)
        }

        let library = LibraryStore(database: db)
        let json = """
        {"ratingKey":"900","title":"A Book","parentTitle":"An Author",
         "Mood":[{"tag":"Series: Dune"},{"tag":"Sequence: Dune #1"}],
         "Style":[{"tag":"Simon Vance"}],"Genre":[{"tag":"Science Fiction"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")

        let sync = SyncStore(database: db)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)

        return (db, library, sync, DownloadStore(database: db))
    }

    private func count(_ db: AudiobookDatabase, _ table: String) throws -> Int {
        try db.writer.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    /// Everything cached goes.
    @Test("The library and the listening state are removed")
    func removesCachedData() throws {
        let (db, _, _, _) = try seeded()

        let books = try count(db, "book")
        let positions = try count(db, "progress")
        #expect(books == 1)
        #expect(positions == 1)

        try db.purgeAllCachedData()

        for table in [
            "book", "track", "book_genre", "book_series", "book_sequence",
            "book_narrator", "book_author", "progress", "bookmark",
            "book_settings", "listening_session", "outbox", "download",
            "cloud_progress",
        ] {
            let remaining = try count(db, table)
            #expect(remaining == 0, "\(table) should be empty")
        }
    }

    /// And the two things that must not.
    ///
    /// Deleting either would sign the device out or make somebody choose their
    /// library again, which is not what "reload everything" means — and neither
    /// comes back from Plex or iCloud without a person doing something.
    @Test("The server and the section survive")
    func keepsIdentity() throws {
        let (db, _, _, _) = try seeded()
        try db.purgeAllCachedData()

        let servers = try count(db, "server")
        let sections = try count(db, "library_section")
        #expect(servers == 1)
        #expect(sections == 1)
    }

    /// The next refresh has to be a full one.
    ///
    /// An incremental sync asks for what changed since a stamp. Leaving the
    /// stamp would ask for changes since a library that is no longer here, and
    /// the answer — nothing much — would look like a refresh that worked.
    @Test("The sync stamp is cleared so the next refresh is full")
    func clearsSyncStamp() throws {
        let (db, _, _, _) = try seeded()

        let before = try db.writer.read { conn in
            try Date.fetchOne(conn, sql: "SELECT last_synced_at FROM library_section")
        }
        #expect(before != nil)

        try db.purgeAllCachedData()

        let after = try db.writer.read { conn in
            try Date.fetchOne(conn, sql: "SELECT last_synced_at FROM library_section")
        }
        #expect(after == nil)
    }

    /// The rows and the bytes are two different things.
    @Test("Evicting everything forgets the rows and names the files")
    func evictAllReturnsPaths() throws {
        let (db, _, _, downloads) = try seeded()

        try db.writer.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO download
                        (part_cache_key, book_rating_key, track_rating_key,
                         state, relative_path, bytes_total, bytes_done)
                    VALUES ('p1', '900', 't1', 'finished', 'a/p1.mp3', 100, 100),
                           ('p2', '900', 't2', 'finished', 'a/p2.mp3', 100, 100)
                    """
            )
        }

        let paths = try downloads.evictAll()

        let remaining = try count(db, "download")
        #expect(Set(paths) == ["a/p1.mp3", "a/p2.mp3"])
        #expect(remaining == 0)
    }

    /// A device with nothing downloaded is not an error.
    @Test("Evicting nothing is fine")
    func evictAllWhenEmpty() throws {
        let (_, _, _, downloads) = try seeded()
        let paths = try downloads.evictAll()
        #expect(paths.isEmpty)
    }

    /// Purging twice is not a failure either — somebody may press it again
    /// while the refresh behind it is still running.
    @Test("Purging an already-purged database is harmless")
    func purgeIsIdempotent() throws {
        let (db, _, _, _) = try seeded()

        try db.purgeAllCachedData()
        try db.purgeAllCachedData()

        let books = try count(db, "book")
        let sections = try count(db, "library_section")
        #expect(books == 0)
        #expect(sections == 1)
    }
}
