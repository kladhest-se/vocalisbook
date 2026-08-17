import Foundation
import Testing
import PlexKit
@testable import Audiobooks

@Suite("Store")
struct StoreTests {
    // Throwing calls are hoisted into a `let` before every #expect / #require.
    //
    // The macros expand their argument into a closure, so a `try` written
    // outside does not cover a throwing call written inside - the compiler
    // reports it against "macro expansion #require", pointing at generated code
    // rather than at the line anybody wrote.

    private func makeDatabase() throws -> AudiobookDatabase {
        try AudiobookDatabase.inMemory()
    }

    /// Creates the server and section rows a book has to hang off.
    ///
    /// `book.library_section_id` references `library_section`, which references
    /// `server`, and foreign keys are enforced — so caching a book before its
    /// section exists fails with SQLite error 19 rather than quietly inserting
    /// an orphan. That ordering is a real constraint on the app too: the server
    /// is stored when a connection is resolved and the section when one is
    /// picked, both before any book is cached.
    @discardableResult
    private func seedSection(_ db: AudiobookDatabase, id: String = "srv:2") throws -> String {
        try db.writer.write { conn in
            let server = ServerRecord(
                machineIdentifier: "srv",
                name: "test",
                lastConnectedURI: nil,
                lastConnectedAt: nil,
                lastConnectionWasRelay: false
            )
            try server.insert(conn)

            let section = LibrarySectionRecord(
                id: id,
                serverID: "srv",
                sectionKey: "2",
                title: "Audiobooks",
                lastSyncedAt: nil
            )
            try section.insert(conn)
        }
        return id
    }

    private func plexBook(_ ratingKey: String = "900") throws -> PlexBook {
        let json = """
        {"ratingKey":"\(ratingKey)","title":"Shadows of the Apt","parentTitle":"Adrian Tchaikovsky",
         "titleSort":"Shadows of the Apt","year":2008,"addedAt":1700000000}
        """
        return try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
    }

    private func plexTracks(_ durations: [Int]) throws -> [PlexTrack] {
        try durations.enumerated().map { index, duration in
            let json = """
            {"ratingKey":"t\(index)","key":"/library/metadata/t\(index)","title":"Part \(index + 1)",
             "index":\(index + 1),"duration":\(duration),
             "Media":[{"Part":[{"id":"p\(index)","key":"/library/parts/p\(index)/1700000000/f.mp3",
             "updatedAt":1700000000}]}]}
            """
            return try JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
        }
    }

    @Test("Migrations apply cleanly to an empty database")
    func migrationsApply() throws {
        let db = try makeDatabase()
        let tables = try db.writer.read { conn in
            try String.fetchAll(
                conn,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        }
        #expect(tables.contains("book"))
        #expect(tables.contains("progress"))
        #expect(tables.contains("outbox"))
        #expect(tables.contains("download"))
    }

    @Test("Cached track offsets are absolute and contiguous")
    func timelineOffsetsAreAbsolute() throws {
        let db = try makeDatabase()
        try seedSection(db)
        let store = LibraryStore(database: db)
        try store.cache(
            book: plexBook(),
            tracks: plexTracks([600_000, 600_000, 300_000]),
            chapters: [],
            sectionID: "srv:2"
        )

        let loaded = try store.timeline(bookRatingKey: "900")
        let cached = try #require(loaded)
        #expect(cached.segments.map(\.startMs) == [0, 600_000, 1_200_000])
        #expect(cached.totalDurationMs == 1_500_000)
        #expect(cached.isConsistent)
    }

    @Test("Caching a book before its section exists is refused, not silently orphaned")
    func bookRequiresItsSection() throws {
        let db = try makeDatabase()
        let store = LibraryStore(database: db)
        // No seedSection here on purpose.
        #expect(throws: (any Error).self) {
            try store.cache(
                book: self.plexBook(),
                tracks: self.plexTracks([600_000]),
                chapters: [],
                sectionID: "srv:2"
            )
        }
    }

    @Test("A book with no cached tracks reads as nil, not as a zero-length book")
    func missingTimelineIsNil() throws {
        let store = LibraryStore(database: try makeDatabase())
        let missing = try store.timeline(bookRatingKey: "nope")
        #expect(missing == nil)
    }

    @Test("Refreshing a book list does not clobber a cached duration")
    func listRefreshPreservesDuration() throws {
        let db = try makeDatabase()
        try seedSection(db)
        let store = LibraryStore(database: db)
        try store.cache(
            book: plexBook(),
            tracks: plexTracks([600_000, 600_000]),
            chapters: [],
            sectionID: "srv:2"
        )
        // Section listings return album rows only — no duration, no tracks.
        try store.cacheBookList([plexBook()], sectionID: "srv:2")

        let books = try store.books(sectionID: "srv:2")
        #expect(books.first?.durationMs == 1_200_000)
        #expect(books.first?.trackCount == 2)
    }

    @Test("An offline session leaves exactly one outbox row per book")
    func outboxCoalesces() throws {
        let db = try makeDatabase()
        let sync = SyncStore(database: db)

        for second in stride(from: 10_000, through: 600_000, by: 10_000) {
            try sync.recordPosition(bookRatingKey: "900", absoluteMs: second)
        }

        let depth = try sync.outboxDepth()
        #expect(depth == 1)
        let pending = try sync.pendingOutbox()
        #expect(pending.count == 1)
        #expect(pending.first?.absoluteMs == 600_000)
    }

    @Test("Position and its outbox entry are written together")
    func positionAndOutboxAreAtomic() throws {
        let db = try makeDatabase()
        let sync = SyncStore(database: db)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 42_000)

        let stored = try sync.progress(bookRatingKey: "900")
        let progress = try #require(stored)
        #expect(progress.absoluteMs == 42_000)
        #expect(progress.dirty)
        let pending = try sync.pendingOutbox()
        #expect(pending.first?.absoluteMs == 42_000)
    }

    @Test("Marking synced clears the queue and records what was pushed")
    func markSyncedClearsDirty() throws {
        let db = try makeDatabase()
        let sync = SyncStore(database: db)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 42_000)
        try sync.markSynced(bookRatingKey: "900", kind: .position, absoluteMs: 42_000)

        let stored = try sync.progress(bookRatingKey: "900")
        let progress = try #require(stored)
        #expect(progress.dirty == false)
        #expect(progress.syncedOffsetMs == 42_000)
        let depth = try sync.outboxDepth()
        #expect(depth == 0)
    }

    @Test("A position recorded while a push was in flight stays dirty")
    func inFlightChangeStaysDirty() throws {
        let db = try makeDatabase()
        let sync = SyncStore(database: db)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 42_000)
        // Playback continued while the request was on the wire.
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 55_000)
        try sync.markSynced(bookRatingKey: "900", kind: .position, absoluteMs: 42_000)

        let stored = try sync.progress(bookRatingKey: "900")
        let progress = try #require(stored)
        #expect(progress.absoluteMs == 55_000)
        #expect(progress.dirty, "the newer position must still be queued")
    }

    @Test("Failed entries back off instead of retrying immediately")
    func failuresBackOff() throws {
        let db = try makeDatabase()
        let sync = SyncStore(database: db)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 42_000)

        let queued = try sync.pendingOutbox()
        let entry = try #require(queued.first)
        try sync.markFailed(entry: entry, error: "connection refused")

        let duringBackoff = try sync.pendingOutbox()
        #expect(duringBackoff.isEmpty, "should be in backoff")
        let later = Date().addingTimeInterval(300)
        let afterBackoff = try sync.pendingOutbox(now: later)
        #expect(afterBackoff.count == 1)
    }

    @Test("Adopting a remote position does not queue it straight back")
    func adoptRemoteDoesNotRequeue() throws {
        let db = try makeDatabase()
        let sync = SyncStore(database: db)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 1_000)
        try sync.adoptRemote(bookRatingKey: "900", absoluteMs: 900_000)

        let stored = try sync.progress(bookRatingKey: "900")
        let progress = try #require(stored)
        #expect(progress.absoluteMs == 900_000)
        #expect(progress.dirty == false)
        let depth = try sync.outboxDepth()
        #expect(depth == 0)
    }

    @Test("Reconciliation reads its timestamps from the store")
    func reconcileFromStore() throws {
        let db = try makeDatabase()
        let sync = SyncStore(database: db)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 4_000_000)

        // Local moved, server did not: push.
        let result = try sync.reconcile(
            bookRatingKey: "900",
            remoteMs: 900_000,
            remoteChangedAt: Date(timeIntervalSince1970: 1)
        )
        #expect(result == .pushLocal(absoluteMs: 4_000_000))
    }

    @Test("Deleted bookmarks leave a tombstone rather than vanishing")
    func bookmarkSoftDelete() throws {
        let db = try makeDatabase()
        let sync = SyncStore(database: db)
        let bookmark = try sync.addBookmark(
            bookRatingKey: "900",
            absoluteMs: 120_000,
            label: "the bit about beetles"
        )
        try sync.deleteBookmark(id: bookmark.id)

        let remaining = try sync.bookmarks(bookRatingKey: "900")
        #expect(remaining.isEmpty)
        let raw = try db.writer.read { conn in
            try BookmarkRecord.fetchOne(conn, key: bookmark.id)
        }
        #expect(raw?.deletedAt != nil, "row must remain as a tombstone for CloudKit")
        #expect(raw?.dirty == true)
    }

    /// Clearing listening data takes the listening data.
    @Test("Purging synced user data clears progress and bookmarks")
    func purgeSyncedClearsUserData() throws {
        let db = try makeDatabase()
        let sync = SyncStore(database: db)

        try seedSection(db)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)
        _ = try sync.addBookmark(bookRatingKey: "900", absoluteMs: 60_000, label: nil)

        try db.purgeSyncedUserData()

        let progress = try sync.progress(bookRatingKey: "900")
        let bookmarks = try sync.bookmarks(bookRatingKey: "900")
        #expect(progress == nil)
        #expect(bookmarks.isEmpty)
    }

    /// And leaves the library alone, which is the whole point of there being two
    /// purges. Clearing a listening history used to empty Browse, Authors and
    /// Genres as well, and cost a full re-fetch to get them back.
    @Test("Purging synced user data keeps the library")
    func purgeSyncedKeepsLibrary() throws {
        let db = try makeDatabase()
        let library = LibraryStore(database: db)

        try seedSection(db)
        try library.cache(
            book: plexBook(),
            tracks: plexTracks([600_000]),
            chapters: [],
            sectionID: "srv:2"
        )

        try db.purgeSyncedUserData()

        let books = try db.writer.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM book") ?? -1
        }
        let sections = try db.writer.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM library_section") ?? -1
        }
        #expect(books == 1)
        #expect(sections == 1)
    }

    @Test("Purging the metadata cache keeps user data")
    func purgeKeepsProgress() throws {
        let db = try makeDatabase()
        let library = LibraryStore(database: db)
        let sync = SyncStore(database: db)

        try seedSection(db)
        try library.cache(
            book: plexBook(),
            tracks: plexTracks([600_000]),
            chapters: [],
            sectionID: "srv:2"
        )
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 42_000)

        try db.purgeMetadataCache()

        let books = try library.books(sectionID: "srv:2")
        #expect(books.isEmpty)
        let survivingProgress = try sync.progress(bookRatingKey: "900")
        #expect(survivingProgress?.absoluteMs == 42_000)
    }
}
