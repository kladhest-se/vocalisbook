import Foundation
import Testing
import PlexKit
@testable import Audiobooks

/// The conflict rule is the whole feature.
///
/// Everything else here is plumbing that a compiler checks; which side wins a
/// merge is a decision, and getting it wrong loses somebody's bookmarks quietly
/// on a device they are not looking at.
@Suite("Cloud sync")
struct CloudSyncStoreTests {

    /// A store with book 900 already cached, because everything that travels
    /// now travels under a book's identity.
    ///
    /// Positions, speeds and sessions are all pushed through a join on `book`,
    /// so a row for a book this device never cached cannot be sent — and there
    /// is no way for the app to be in that state. Tests written before that was
    /// true were asserting against a shape that no longer exists.
    ///
    /// Seeded here rather than at eleven call sites: the requirement belongs to
    /// the store, not to any one test.
    private func makeStores() throws -> (CloudSyncStore, BookmarkStore, SyncStore, AudiobookDatabase) {
        let db = try AudiobookDatabase.inMemory()

        try db.writer.write { conn in
            let server = ServerRecord(
                machineIdentifier: "srv", name: "test",
                lastConnectedURI: nil, lastConnectedAt: nil, lastConnectionWasRelay: false
            )
            try server.insert(conn)
            let section = LibrarySectionRecord(
                id: "srv:2", serverID: "srv", sectionKey: "2",
                title: "Audiobooks", lastSyncedAt: nil
            )
            try section.insert(conn)
        }

        let json = """
        {"ratingKey":"900","title":"A Book",
         "guid":"com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en"}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try LibraryStore(database: db).cacheBookList([book], sectionID: "srv:2")

        return (CloudSyncStore(database: db), BookmarkStore(database: db), SyncStore(database: db), db)
    }

    @Test("A new bookmark is pending until it is pushed")
    func newBookmarkIsPending() throws {
        let (cloud, bookmarks, _, _) = try makeStores()
        let added = try bookmarks.add(bookRatingKey: "900", absoluteMs: 1_000)

        let pending = try cloud.pendingChanges()
        #expect(pending.count == 1)
        #expect(pending.first?.kind == .bookmark)
        #expect(pending.first?.id == added.id)

        try cloud.markPushed(pending)
        let after = try cloud.pendingChanges()
        #expect(after.isEmpty)
    }

    /// The case that strands an edit for ever.
    @Test("An edit made during a push is not marked as pushed")
    func editDuringPushSurvives() throws {
        let (cloud, bookmarks, _, _) = try makeStores()
        let added = try bookmarks.add(bookRatingKey: "900", absoluteMs: 1_000)
        let inFlight = try cloud.pendingChanges()

        // The rename bumps the revision while the push is notionally in flight.
        try bookmarks.setLabel("The good bit", id: added.id)

        try cloud.markPushed(inFlight)

        // Still pending, because what was acknowledged is not what is here now.
        let pending = try cloud.pendingChanges()
        #expect(pending.count == 1)
        #expect(pending.first?.fields["label"]?.stringValue == "The good bit")
    }

    @Test("A newer remote record is adopted")
    func newerRemoteWins() throws {
        let (cloud, bookmarks, _, _) = try makeStores()
        let added = try bookmarks.add(bookRatingKey: "900", absoluteMs: 1_000)

        let remote = CloudRecord(
            kind: .bookmark,
            id: added.id,
            revision: added.revision + 5,
            fields: [
                "bookRatingKey": .string("900"),
                "absoluteMs": .int(2_000),
                "label": .string("From the phone"),
                "createdAt": .date(added.createdAt),
            ]
        )

        let result = try cloud.apply([remote])
        #expect(result.applied == 1)

        let stored = try bookmarks.bookmarks(bookRatingKey: "900")
        #expect(stored.first?.absoluteMs == 2_000)
        #expect(stored.first?.label == "From the phone")
    }

    /// The local side keeps its edit *and* stays dirty, which is how the other
    /// device finds out it was behind.
    @Test("An older remote record is rejected and the local edit stays pending")
    func olderRemoteLoses() throws {
        let (cloud, bookmarks, _, _) = try makeStores()
        let added = try bookmarks.add(bookRatingKey: "900", absoluteMs: 1_000)
        try bookmarks.setLabel("Local", id: added.id)

        let remote = CloudRecord(
            kind: .bookmark,
            id: added.id,
            revision: 1,
            fields: ["bookRatingKey": .string("900"), "absoluteMs": .int(9_999)]
        )

        let result = try cloud.apply([remote])
        #expect(result.rejected == 1)

        let stored = try bookmarks.bookmarks(bookRatingKey: "900")
        #expect(stored.first?.label == "Local")

        let pending = try cloud.pendingChanges()
        #expect(pending.count == 1)
    }

    /// Applying a remote change must not make the row look locally edited, or
    /// two devices trade the same record for ever.
    @Test("An adopted record is not pending afterwards")
    func adoptedRecordIsNotPending() throws {
        let (cloud, bookmarks, _, _) = try makeStores()
        let added = try bookmarks.add(bookRatingKey: "900", absoluteMs: 1_000)
        try cloud.markPushed(try cloud.pendingChanges())

        let remote = CloudRecord(
            kind: .bookmark,
            id: added.id,
            revision: added.revision + 1,
            fields: ["bookRatingKey": .string("900"), "absoluteMs": .int(3_000)]
        )
        try cloud.apply([remote])

        let pending = try cloud.pendingChanges()
        #expect(pending.isEmpty)
    }

    /// A deletion that does not travel is a bookmark that comes back.
    @Test("A deletion is pending, and carries as a tombstone")
    func deletionTravels() throws {
        let (cloud, bookmarks, _, _) = try makeStores()
        let added = try bookmarks.add(bookRatingKey: "900", absoluteMs: 1_000)
        try cloud.markPushed(try cloud.pendingChanges())

        try bookmarks.delete(id: added.id)

        let pending = try cloud.pendingChanges()
        #expect(pending.count == 1)
        #expect(pending.first?.isDeleted == true)
    }

    @Test("A remote tombstone removes the bookmark here")
    func remoteTombstoneApplies() throws {
        let (cloud, bookmarks, _, _) = try makeStores()
        let added = try bookmarks.add(bookRatingKey: "900", absoluteMs: 1_000)

        let remote = CloudRecord(
            kind: .bookmark,
            id: added.id,
            revision: added.revision + 1,
            isDeleted: true,
            fields: ["deletedAt": .date(Date())]
        )
        try cloud.apply([remote])

        let stored = try bookmarks.bookmarks(bookRatingKey: "900")
        #expect(stored.isEmpty)
    }

    /// A record this device has never seen arrives as an insert, not a no-op.
    @Test("A record from another device that is unknown here is inserted")
    func unknownRecordIsInserted() throws {
        let (cloud, bookmarks, _, _) = try makeStores()

        let remote = CloudRecord(
            kind: .bookmark,
            id: "from-the-mac",
            revision: 1,
            fields: [
                "bookRatingKey": .string("900"),
                "absoluteMs": .int(4_242),
                "createdAt": .date(Date()),
            ]
        )
        try cloud.apply([remote])

        let stored = try bookmarks.bookmarks(bookRatingKey: "900")
        #expect(stored.count == 1)
        #expect(stored.first?.absoluteMs == 4_242)
    }

    @Test("Per-book speed syncs the same way")
    func speedSyncs() throws {
        let (cloud, _, sync, _) = try makeStores()
        try sync.setRate(1.5, bookRatingKey: "900")

        let pending = try cloud.pendingChanges()
        // Keyed by the book's identity now, not its rating key: a speed that
        // travelled under a rating key arrived for whatever book held that
        // number on the other server.
        #expect(pending.contains {
            $0.kind == .bookSettings && $0.id == "spokenmeta:audible:us:B08G9PRS1K"
        })

        let remote = CloudRecord(
            kind: .bookSettings,
            id: "spokenmeta:audible:us:B08G9PRS1K",
            revision: 99,
            fields: ["rate": .double(2.0)]
        )
        try cloud.apply([remote])

        let rate = try sync.rate(bookRatingKey: "900")
        #expect(rate == 2.0)
    }

    /// Record names share one namespace in CloudKit, so a bookmark id and a
    /// book's rating key must not be able to collide.
    @Test("Record names are unique across kinds")
    func recordNamesAreNamespaced() {
        let bookmark = CloudRecord(kind: .bookmark, id: "900", revision: 1, fields: [:])
        let settings = CloudRecord(kind: .bookSettings, id: "900", revision: 1, fields: [:])

        #expect(bookmark.recordName != settings.recordName)
    }

    @Test("A listening session is pending, and closing it supersedes the open one")
    func sessionsSync() throws {
        let (cloud, _, _, db) = try makeStores()
        let sessions = SessionStore(database: db)

        _ = try sessions.begin(bookRatingKey: "900", atMs: 0, rate: 1.0)
        let open = try cloud.pendingChanges()
        let started = try #require(open.first { $0.kind == .listeningSession })
        #expect(started.fields["endedAt"] == nil)

        try sessions.end(atMs: 60_000)
        let closed = try cloud.pendingChanges()
        let finished = try #require(closed.first { $0.kind == .listeningSession })

        #expect(finished.id == started.id)
        #expect(finished.revision > started.revision)
        #expect(finished.fields["endMs"]?.intValue == 60_000)
    }

    @Test("A session from another device is inserted")
    func remoteSessionInserted() throws {
        let (cloud, _, _, db) = try makeStores()
        let sessions = SessionStore(database: db)

        let remote = CloudRecord(
            kind: .listeningSession,
            id: "from-the-mac",
            revision: 2,
            fields: [
                "bookRatingKey": .string("900"),
                "startedAt": .date(Date(timeIntervalSince1970: 1_700_000_000)),
                "endedAt": .date(Date(timeIntervalSince1970: 1_700_003_600)),
                "startMs": .int(0),
                "endMs": .int(3_600_000),
                "rate": .double(1.0),
            ]
        )
        try cloud.apply([remote])

        // Queried for the day the session belongs to rather than through
        // `stats()`, whose windows are relative to today — that would make this
        // pass or fail depending on the date it runs on.
        let day = try sessions.sessions(on: Date(timeIntervalSince1970: 1_700_000_000))
        let stored = try #require(day.first { $0.id == "from-the-mac" })
        #expect(stored.endMs == 3_600_000)

        // Applied, not queued to be pushed straight back.
        let pending = try cloud.pendingChanges()
        #expect(pending.isEmpty)
    }

    /// History is append-only and by far the most numerous. A device with a
    /// thousand unsynced sessions must still get its bookmarks across in the
    /// first batch, rather than spending every batch on history nobody is
    /// waiting for.
    @Test("Bookmarks and speeds come before history in a batch")
    func historyDoesNotCrowdOutTheRest() throws {
        let (cloud, bookmarks, sync, db) = try makeStores()
        let sessions = SessionStore(database: db)

        // The five books these sessions belong to. The harness caches one, and
        // a session for a book this device never cached is not pushed at all
        // now — so four of the five would simply not have been in the batch,
        // and the test would have been measuring the join rather than the
        // ordering it is about.
        let library = LibraryStore(database: db)
        let extra = try (1..<5).map { index -> PlexBook in
            let json = """
            {"ratingKey":"90\(index)","title":"Book \(index)",
             "guid":"com.plexapp.agents.spokenmeta://B08G9PRS1\(index)_us"}
            """
            return try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        }
        try library.cacheBookList(extra, sectionID: "srv:2")

        for index in 0..<5 {
            _ = try sessions.begin(bookRatingKey: "90\(index)", atMs: 0, rate: 1.0)
            try sessions.end(atMs: 1_000)
        }
        _ = try bookmarks.add(bookRatingKey: "900", absoluteMs: 1_000)
        try sync.setRate(1.5, bookRatingKey: "900")

        // Two slots, two higher-priority records: history does not get in.
        let tight = try cloud.pendingChanges(limit: 2)
        #expect(tight.count == 2)
        #expect(tight.contains { $0.kind == .bookmark })
        #expect(tight.contains { $0.kind == .bookSettings })
        #expect(tight.allSatisfy { $0.kind != .listeningSession })

        // With room to spare, history fills the rest — "last" means last, not
        // never. The first version of this test asserted that a batch of three
        // held no sessions when only two other records existed, which demanded
        // the batch be left short. The code was right; the expectation was not.
        let roomy = try cloud.pendingChanges(limit: 4)
        #expect(roomy.count == 4)
        #expect(roomy.filter { $0.kind == .listeningSession }.count == 2)
        #expect(roomy.prefix(2).allSatisfy { $0.kind != .listeningSession })
    }

    /// Every kind must be mapped in both directions. A case added to the enum
    /// and forgotten in `pendingChanges` is a table that silently never syncs.
    @Test("Every kind has a distinct record name")
    func everyKindIsNamespaced() {
        let names = CloudRecord.Kind.allCases.map {
            CloudRecord(kind: $0, id: "900", revision: 1, fields: [:]).recordName
        }
        #expect(Set(names).count == CloudRecord.Kind.allCases.count)
    }
    /// The two flags mean different things and must not clear each other.
    ///
    /// `dirty` is Plex's, `cloud_dirty` is iCloud's. Sharing one would mean
    /// whichever destination acknowledged first marked the row clean and the
    /// other never saw the position at all.
    @Test("Pushing to iCloud does not tell Plex the position was sent")
    func cloudPushLeavesPlexFlag() throws {
        // A cached book, because progress now travels under that book's
        // identity: no book row, no identity, nothing to push and nothing for an
        // arriving record to resolve to. These tests predate that and were
        // asserting against a state the app cannot be in.
        let (cloud, library, sync, _) = try makeSeededStores()
        try cacheMatchedBook(library)

        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 90_000)

        let pending = try cloud.pendingChanges()
        let position = try #require(pending.first { $0.kind == .progress })
        try cloud.markPushed([position])

        let stored = try sync.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.cloudDirty == false)
        #expect(after.dirty == true)
    }

    /// A position from another device has to reach Plex as well, or this becomes
    /// a private conversation between VocalisBook installs and every other Plex
    /// client is left behind.
    @Test("An arriving position is queued for Plex")
    func arrivingPositionQueuesForPlex() throws {
        let (cloud, library, _, db) = try makeSeededStores()
        try cacheMatchedBook(library)

        let incoming = CloudRecord(
            kind: .progress,
            id: "spokenmeta:audible:us:B08G9PRS1K",
            revision: 4,
            fields: [
                "absoluteMs": .int(120_000),
                "changedAt": .date(Date()),
            ]
        )

        let result = try cloud.apply([incoming])
        #expect(result.applied == 1)

        let queued = try db.writer.read { conn in
            try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(*) FROM outbox WHERE book_rating_key = '900'"
            ) ?? 0
        }
        #expect(queued == 1)
    }

    /// And it must not be sent straight back out as though this device had made
    /// the change.
    @Test("An arriving position is not queued for iCloud again")
    func arrivingPositionDoesNotEcho() throws {
        // Seeded, so the record actually lands in `progress`. Without a cached
        // book it goes to the inbox instead — and an inbox row is not pending
        // either, so this passed while testing nothing.
        let (cloud, library, _, _) = try makeSeededStores()
        try cacheMatchedBook(library)

        let incoming = CloudRecord(
            kind: .progress,
            id: "spokenmeta:audible:us:B08G9PRS1K",
            revision: 4,
            fields: ["absoluteMs": .int(120_000), "changedAt": .date(Date())]
        )
        _ = try cloud.apply([incoming])

        let pending = try cloud.pendingChanges()
        #expect(!pending.contains { $0.kind == .progress })
    }


    /// The rule that was wrong, and the reason two devices never agreed.
    ///
    /// A revision is a per-device counter. A television used for a year sits at
    /// four hundred; a phone bought last week sits at three. Ordering by
    /// revision compares how much each device has been used, not when anything
    /// happened — so the older device won every exchange for ever.
    @Test("A newer position wins even when the local revision is higher")
    func newerTimeBeatsHigherRevision() throws {
        // A cached book, because progress now travels under that book's
        // identity: no book row, no identity, nothing to push and nothing for an
        // arriving record to resolve to. These tests predate that and were
        // asserting against a state the app cannot be in.
        let (cloud, library, sync, _) = try makeSeededStores()
        try cacheMatchedBook(library)

        // This device has written many times, so its counter is high.
        for ms in stride(from: 10_000, through: 100_000, by: 10_000) {
            try sync.recordPosition(bookRatingKey: "900", absoluteMs: ms)
        }
        let local = try sync.progress(bookRatingKey: "900")
        let localRevision = try #require(local).revision
        #expect(localRevision > 3)

        // The other device has written three times, and more recently.
        let incoming = CloudRecord(
            kind: .progress,
            id: "spokenmeta:audible:us:B08G9PRS1K",
            revision: 3,
            fields: [
                "absoluteMs": .int(500_000),
                "changedAt": .date(Date().addingTimeInterval(60)),
            ]
        )

        let result = try cloud.apply([incoming])
        #expect(result.applied == 1)

        let stored = try sync.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 500_000)
    }

    /// And the other direction still holds, or two devices would overwrite each
    /// other in a loop.
    @Test("An older position loses even when its revision is higher")
    func olderTimeLosesDespiteRevision() throws {
        // A cached book, because progress now travels under that book's
        // identity: no book row, no identity, nothing to push and nothing for an
        // arriving record to resolve to. These tests predate that and were
        // asserting against a state the app cannot be in.
        let (cloud, library, sync, _) = try makeSeededStores()
        try cacheMatchedBook(library)

        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 400_000)

        let stale = CloudRecord(
            kind: .progress,
            id: "spokenmeta:audible:us:B08G9PRS1K",
            revision: 999,
            fields: [
                "absoluteMs": .int(1_000),
                "changedAt": .date(Date().addingTimeInterval(-3_600)),
            ]
        )

        let result = try cloud.apply([stale])
        #expect(result.rejected == 1)

        let stored = try sync.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 400_000)
    }

    /// Finishing a book has to travel, or it stays in Continue listening on
    /// every other device for ever.
    @Test("A finished book arrives finished")
    func finishedTravels() throws {
        // A cached book, because the record names an identity and resolving it
        // needs a `book` row. Without one it goes to the inbox and waits — which
        // is correct, and not what this test is about.
        let (cloud, library, sync, _) = try makeSeededStores()
        try cacheMatchedBook(library)

        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 100_000)

        let finished = CloudRecord(
            kind: .progress,
            id: "spokenmeta:audible:us:B08G9PRS1K",
            revision: 2,
            fields: [
                "absoluteMs": .int(600_000),
                "changedAt": .date(Date().addingTimeInterval(60)),
                "finishedAt": .date(Date().addingTimeInterval(60)),
            ]
        )
        _ = try cloud.apply([finished])

        let stored = try sync.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.finishedAt != nil)

        // Which is what takes it out of the list.
        let listed = try library.continueListening()
        #expect(!listed.contains { $0.ratingKey == "900" })
    }

    // MARK: - Identity-keyed progress

    /// The existing harness plus a section, which caching a book requires.
    private func makeSeededStores() throws -> (CloudSyncStore, LibraryStore, SyncStore, AudiobookDatabase) {
        let db = try AudiobookDatabase.inMemory()

        try db.writer.write { conn in
            let server = ServerRecord(
                machineIdentifier: "srv", name: "test",
                lastConnectedURI: nil, lastConnectedAt: nil, lastConnectionWasRelay: false
            )
            try server.insert(conn)
            let section = LibrarySectionRecord(
                id: "srv:2", serverID: "srv", sectionKey: "2",
                title: "Audiobooks", lastSyncedAt: nil
            )
            try section.insert(conn)
        }

        return (
            CloudSyncStore(database: db),
            LibraryStore(database: db),
            SyncStore(database: db),
            db
        )
    }

    private func cacheMatchedBook(
        _ library: LibraryStore,
        ratingKey: String = "900",
        asin: String = "B08G9PRS1K"
    ) throws {
        let json = """
        {"ratingKey":"\(ratingKey)","title":"A Book",
         "guid":"com.plexapp.agents.spokenmeta://\(asin)_us?lang=en"}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")
    }

    /// A rating key means nothing on another server, so the record carries the
    /// identity instead.
    @Test("A position is pushed under its durable identity")
    func pushesUnderIdentity() throws {
        let (cloud, library, sync, _) = try makeSeededStores()

        try cacheMatchedBook(library)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 90_000)

        let pending = try cloud.pendingChanges()
        let position = try #require(pending.first { $0.kind == .progress })
        #expect(position.id == "spokenmeta:audible:us:B08G9PRS1K")
    }

    /// And arrives back on a device where the same book has a different rating
    /// key, which is the entire point.
    @Test("An arriving identity resolves to this device's rating key")
    func resolvesToLocalRatingKey() throws {
        let (cloud, library, sync, _) = try makeSeededStores()

        // Same book, different server, different rating key.
        try cacheMatchedBook(library, ratingKey: "742")

        let incoming = CloudRecord(
            kind: .progress,
            id: "spokenmeta:audible:us:B08G9PRS1K",
            revision: 3,
            fields: ["absoluteMs": .int(120_000), "changedAt": .date(Date())]
        )
        let result = try cloud.apply([incoming])
        #expect(result.applied == 1)

        let stored = try sync.progress(bookRatingKey: "742")
        let after = try #require(stored)
        #expect(after.absoluteMs == 120_000)
    }

    /// The case that makes this more than a rename.
    ///
    /// A television that has not synced its library yet has no book to attach
    /// the position to. Dropping it loses the position for good — nothing sends
    /// it again, because the sending device believes it was delivered.
    @Test("A position for an uncached book is held, then claimed")
    func heldUntilTheBookArrives() throws {
        let (cloud, library, sync, _) = try makeSeededStores()

        let incoming = CloudRecord(
            kind: .progress,
            id: "spokenmeta:audible:us:B08G9PRS1K",
            revision: 3,
            fields: ["absoluteMs": .int(300_000), "changedAt": .date(Date())]
        )
        let result = try cloud.apply([incoming])
        #expect(result.applied == 1)

        // Nowhere to put it yet.
        let before = try sync.progress(bookRatingKey: "900")
        #expect(before == nil)

        // The library syncs, and the position is waiting.
        try cacheMatchedBook(library)

        let stored = try sync.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 300_000)
    }

    /// Records made before this change name a rating key. They are still in the
    /// container and no migration can rewrite another device's records.
    @Test("A legacy rating-key record still applies")
    func legacyRecordStillApplies() throws {
        let (cloud, library, sync, _) = try makeSeededStores()

        try cacheMatchedBook(library)

        let legacy = CloudRecord(
            kind: .progress,
            id: "900",
            revision: 2,
            fields: ["absoluteMs": .int(45_000), "changedAt": .date(Date())]
        )
        let result = try cloud.apply([legacy])
        #expect(result.applied == 1)

        let stored = try sync.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 45_000)
    }

    /// A held record must not roll back listening that happened here in the
    /// meantime.
    @Test("A held position does not overwrite something newer")
    func heldDoesNotOverwriteNewer() throws {
        let (cloud, library, sync, _) = try makeSeededStores()

        let old = CloudRecord(
            kind: .progress,
            id: "spokenmeta:audible:us:B08G9PRS1K",
            revision: 1,
            fields: [
                "absoluteMs": .int(10_000),
                "changedAt": .date(Date(timeIntervalSince1970: 1_600_000_000)),
            ]
        )
        _ = try cloud.apply([old])

        // Listened to here first, under a rating key nothing had matched yet.
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 500_000)
        try cacheMatchedBook(library)

        let stored = try sync.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 500_000)
    }

    /// The migration that did half its job.
    ///
    /// v7 added `identity_key` and left it null for every book already cached,
    /// and only a fresh cache fills it. Pushing requires it and arriving records
    /// resolve through it, so after upgrading nothing synced until the whole
    /// library happened to be refreshed — which is what "flaky" looked like from
    /// outside.
    @Test("A book cached before the identity column still pushes")
    func backfilledIdentityPushes() throws {
        let (cloud, _, sync, db) = try makeSeededStores()

        // A book as v6 would have left it: no identity at all.
        try db.writer.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO book (rating_key, library_section_id, title, cached_at)
                    VALUES ('900', 'srv:2', 'A Book', ?)
                    """,
                arguments: [Date()]
            )
            try conn.execute(sql: "UPDATE book SET identity_key = NULL WHERE rating_key = '900'")
        }

        // What v9 does on opening the database.
        try db.writer.write { conn in
            try conn.execute(sql: """
                UPDATE book
                SET identity_key = 'plex:'
                    || substr(library_section_id, 1, instr(library_section_id, ':') - 1)
                    || ':' || rating_key
                WHERE identity_key IS NULL
                  AND instr(library_section_id, ':') > 1
                """)
        }

        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 90_000)

        let pending = try cloud.pendingChanges()
        let position = try #require(pending.first { $0.kind == .progress })
        #expect(position.id == "plex:srv:900")
    }

    /// One device has refreshed and holds a provider identity; another has not
    /// and still sends the per-server form. Both point at the same server, so the
    /// rating key is the same on both and they should agree.
    @Test("A per-server record resolves on the same server")
    func perServerRecordResolves() throws {
        let (cloud, library, sync, _) = try makeSeededStores()
        try cacheMatchedBook(library)   // identity is spokenmeta:…

        let incoming = CloudRecord(
            kind: .progress,
            id: "plex:srv:900",
            revision: 2,
            fields: ["absoluteMs": .int(240_000), "changedAt": .date(Date())]
        )
        let result = try cloud.apply([incoming])
        #expect(result.applied == 1)

        let stored = try sync.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 240_000)
    }

    /// And it does not reach across servers, which is what the per-server form
    /// means.
    @Test("A per-server record from another server is held, not applied")
    func otherServerRecordHeld() throws {
        let (cloud, library, sync, _) = try makeSeededStores()
        try cacheMatchedBook(library)

        let incoming = CloudRecord(
            kind: .progress,
            id: "plex:elsewhere:742",
            revision: 2,
            fields: ["absoluteMs": .int(240_000), "changedAt": .date(Date())]
        )
        _ = try cloud.apply([incoming])

        let stored = try sync.progress(bookRatingKey: "900")
        #expect(stored == nil)
    }

    // MARK: - Identity for everything else

    /// A bookmark's own id was already portable; the field naming its book was
    /// not. Arriving on another server it attached itself to whatever book
    /// happened to hold that number there — a bookmark in the wrong book, which
    /// nothing would ever report as an error.
    @Test("A bookmark travels under its book's identity")
    func bookmarkCarriesIdentity() throws {
        let (cloud, library, _, db) = try makeSeededStores()
        try cacheMatchedBook(library)

        let bookmarks = BookmarkStore(database: db)
        _ = try bookmarks.add(bookRatingKey: "900", absoluteMs: 60_000)

        let pending = try cloud.pendingChanges()
        let record = try #require(pending.first { $0.kind == .bookmark })
        #expect(record.fields["bookIdentity"]?.stringValue == "spokenmeta:audible:us:B08G9PRS1K")
    }

    /// And lands on the local rating key for that book, whatever number it has
    /// here.
    @Test("An arriving bookmark resolves to this device's book")
    func bookmarkResolvesOnArrival() throws {
        let (cloud, library, _, db) = try makeSeededStores()
        try cacheMatchedBook(library, ratingKey: "742")

        let incoming = CloudRecord(
            kind: .bookmark,
            id: "bm-1",
            revision: 1,
            fields: [
                "bookIdentity": .string("spokenmeta:audible:us:B08G9PRS1K"),
                "bookRatingKey": .string("900"),
                "absoluteMs": .int(90_000),
                "createdAt": .date(Date()),
            ]
        )
        _ = try cloud.apply([incoming])

        let stored = try db.writer.read { conn in
            try String.fetchOne(
                conn, sql: "SELECT book_rating_key FROM bookmark WHERE id = 'bm-1'"
            )
        }
        #expect(stored == "742")
    }

    /// A playback speed keyed by another server's number is a speed applied to
    /// the wrong book.
    @Test("Book settings travel under the identity")
    func settingsCarryIdentity() throws {
        let (cloud, library, _, db) = try makeSeededStores()
        try cacheMatchedBook(library)

        try db.writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO book_settings (book_rating_key, rate, revision, dirty)
                VALUES ('900', 1.5, 1, 1)
                """)
        }

        let pending = try cloud.pendingChanges()
        let record = try #require(pending.first { $0.kind == .bookSettings })
        #expect(record.id == "spokenmeta:audible:us:B08G9PRS1K")

        // And the flag clears, which needs the identity resolved back the other
        // way. Without that the speed is pushed again on every sync for ever.
        try cloud.markPushed([record])
        let stillDirty = try db.writer.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM book_settings WHERE dirty = 1") ?? 0
        }
        #expect(stillDirty == 0)
    }

    /// Held positions for books that are never coming.
    @Test("The inbox forgets rows nothing will ever claim")
    func inboxIsPruned() throws {
        let (cloud, _, _, db) = try makeSeededStores()

        // One from a month and a half ago, one from today.
        try db.writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO cloud_progress
                    (identity_key, absolute_ms, changed_at, revision)
                VALUES ('spokenmeta:audible:us:OLDOLDOLD1', 1000, ?, 1),
                       ('spokenmeta:audible:us:NEWNEWNEW1', 2000, ?, 1)
                """, arguments: [
                    Date().addingTimeInterval(-45 * 24 * 60 * 60),
                    Date(),
                ])
        }

        // Applying anything is what sweeps, because it is the only thing that
        // adds.
        _ = try cloud.apply([
            CloudRecord(
                kind: .progress,
                id: "spokenmeta:audible:us:SOMETHING1",
                revision: 1,
                fields: ["absoluteMs": .int(500), "changedAt": .date(Date())]
            ),
        ])

        let held = try db.writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT identity_key FROM cloud_progress ORDER BY identity_key")
        }
        #expect(!held.contains("spokenmeta:audible:us:OLDOLDOLD1"))
        #expect(held.contains("spokenmeta:audible:us:NEWNEWNEW1"))
    }

}

