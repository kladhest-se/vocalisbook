import Foundation
import Testing
import GRDB
@testable import Audiobooks

/// Finishing a book, and starting it again.
///
/// `markFinished` existed and only ever fired when a book played to its last
/// second. A book can be finished without that — abandoned, or listened to
/// somewhere else — and a finished one can be started again.
@Suite("Finishing and resetting")
struct ResetProgressTests {

    private func makeStore() throws -> (SyncStore, AudiobookDatabase) {
        let db = try AudiobookDatabase.inMemory()
        return (SyncStore(database: db), db)
    }

    @Test("Resetting puts the position back to the beginning")
    func resetsPosition() throws {
        let (store, _) = try makeStore()
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 3_600_000)

        try store.resetProgress(bookRatingKey: "900")

        let progress = try store.progress(bookRatingKey: "900")
        #expect(progress?.absoluteMs == 0)
    }

    /// A book at zero that still says it was finished is one the library keeps
    /// filing under done — invisible in Continue listening, and marked read on
    /// every other client.
    @Test("Resetting unfinishes a finished book")
    func clearsFinished() throws {
        let (store, _) = try makeStore()
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 3_600_000)
        try store.markFinished(bookRatingKey: "900")

        try store.resetProgress(bookRatingKey: "900")

        let progress = try store.progress(bookRatingKey: "900")
        #expect(progress?.finishedAt == nil)
    }

    /// The revision is what stops another device pushing the old position back.
    /// A local write that did not bump it would be undone by the next sync,
    /// which is the failure the outbox exists to prevent.
    @Test("Resetting bumps the revision past what came before")
    func bumpsRevision() throws {
        let (store, _) = try makeStore()
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 3_600_000)
        let recorded = try store.progress(bookRatingKey: "900")
        let before = try #require(recorded).revision

        try store.resetProgress(bookRatingKey: "900")

        let reset = try store.progress(bookRatingKey: "900")
        let after = try #require(reset).revision
        #expect(after > before)
    }

    @Test("Resetting queues the change, so the server hears about it")
    func queuesTheChange() throws {
        let (store, db) = try makeStore()
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 3_600_000)
        try store.resetProgress(bookRatingKey: "900")

        let pending = try db.writer.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        }
        #expect(pending > 0)
    }

    /// Marking finished by hand, on a book that was never played.
    @Test("A book with no progress can still be marked finished")
    func finishAnUnplayedBook() throws {
        let (store, _) = try makeStore()

        try store.markFinished(bookRatingKey: "900")

        let progress = try store.progress(bookRatingKey: "900")
        #expect(progress?.finishedAt != nil)
        #expect(progress?.absoluteMs == 0)
    }

    /// And resetting one that was never played should not fail either — the row
    /// may not exist at all.
    @Test("Resetting a book that was never played is not an error")
    func resetWithoutProgress() throws {
        let (store, _) = try makeStore()

        try store.resetProgress(bookRatingKey: "900")

        let progress = try store.progress(bookRatingKey: "900")
        #expect(progress?.absoluteMs == 0)
        #expect(progress?.finishedAt == nil)
    }
    /// Unfinishing has to reach the server, not just the local row.
    ///
    /// Plex records completion per track. A position of zero leaves every track
    /// scrobbled, so the book reads as fully played there and unstarted here —
    /// which is what the new checkmark would have produced every time somebody
    /// pressed it twice.
    @Test("Resetting a finished book queues an unfinish, not a position")
    func resettingFinishedUnscrobbles() throws {
        let db = try AudiobookDatabase.inMemory()
        let sync = SyncStore(database: db)

        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)
        try sync.markFinished(bookRatingKey: "900")
        try sync.resetProgress(bookRatingKey: "900")

        // The set, not the last one.
        //
        // `id` is a UUID, so ordering by it is ordering by chance — the first
        // version of this test read the outbox that way and passed or failed on
        // which random string sorted higher.
        //
        // And what matters is not which came last but that only one is there:
        // `finished` and `unfinished` contradict each other, and both being
        // queued means scrobbling every track and then unscrobbling every one.
        let kinds = try db.writer.read { conn in
            try String.fetchAll(
                conn, sql: "SELECT kind FROM outbox WHERE book_rating_key = '900'"
            )
        }
        #expect(kinds.contains("unfinished"))
        #expect(!kinds.contains("finished"))
    }

    /// And restarting a book somebody is halfway through has nothing to
    /// unscrobble — asking Plex to unscrobble tracks it never marked is a
    /// request per track for nothing.
    @Test("Resetting an unfinished book queues a position")
    func resettingUnfinishedQueuesPosition() throws {
        let db = try AudiobookDatabase.inMemory()
        let sync = SyncStore(database: db)

        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)
        try sync.resetProgress(bookRatingKey: "900")

        let kinds = try db.writer.read { conn in
            try String.fetchAll(
                conn, sql: "SELECT kind FROM outbox WHERE book_rating_key = '900'"
            )
        }
        #expect(kinds.contains("position"))
        #expect(!kinds.contains("unfinished"))
    }

    /// Pressing the tick twice before the outbox drains.
    ///
    /// The queue coalesces per kind, so finishing and unfinishing produced two
    /// rows that contradict each other. Sending both is two requests per track
    /// to reach the state one of them describes — and a drain interrupted
    /// between them leaves the book finished on the server when somebody said it
    /// was not.
    @Test("Finishing after unfinishing leaves one instruction, not two")
    func contradictionsCancel() throws {
        let db = try AudiobookDatabase.inMemory()
        let sync = SyncStore(database: db)

        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)
        try sync.markFinished(bookRatingKey: "900")
        try sync.resetProgress(bookRatingKey: "900")
        try sync.markFinished(bookRatingKey: "900")

        let kinds = try db.writer.read { conn in
            try String.fetchAll(
                conn, sql: "SELECT kind FROM outbox WHERE book_rating_key = '900'"
            )
        }
        #expect(kinds.contains("finished"))
        #expect(!kinds.contains("unfinished"))
    }

    /// A position is not an opposite of anything: a book can be finished and
    /// still have a place in it, which is what `markFinished` leaves behind.
    @Test("A position and a finish can both be queued")
    func positionSurvivesFinishing() throws {
        let db = try AudiobookDatabase.inMemory()
        let sync = SyncStore(database: db)

        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)
        try sync.markFinished(bookRatingKey: "900")

        let kinds = try db.writer.read { conn in
            try String.fetchAll(
                conn, sql: "SELECT kind FROM outbox WHERE book_rating_key = '900'"
            )
        }
        #expect(kinds.contains("position"))
        #expect(kinds.contains("finished"))
    }

}
