import Foundation
import GRDB

/// Owns everything that has to survive being offline: position, bookmarks, and
/// the queue of mutations waiting to reach Plex.
public struct SyncStore: Sendable {
    private let database: AudiobookDatabase

    public init(database: AudiobookDatabase) {
        self.database = database
    }

    // MARK: - Position

    public func recordPosition(
        bookRatingKey: String,
        absoluteMs: Int,
        at now: Date = Date()
    ) throws {
        try database.writer.write { db in
            let existing = try ProgressRecord.fetchOne(db, key: bookRatingKey)
            let progress = ProgressRecord(
                bookRatingKey: bookRatingKey,
                absoluteMs: absoluteMs,
                changedAt: now,
                syncedOffsetMs: existing?.syncedOffsetMs,
                syncedAt: existing?.syncedAt,
                finishedAt: existing?.finishedAt,
                revision: (existing?.revision ?? 0) + 1,
                dirty: true
            )
            try progress.save(db)
            try Self.enqueue(
                db,
                bookRatingKey: bookRatingKey,
                kind: .position,
                absoluteMs: absoluteMs,
                at: now,
                revision: progress.revision
            )
        }
    }

    public func markFinished(bookRatingKey: String, at now: Date = Date()) throws {
        try database.writer.write { db in
            let existing = try ProgressRecord.fetchOne(db, key: bookRatingKey)
            let progress = ProgressRecord(
                bookRatingKey: bookRatingKey,
                absoluteMs: existing?.absoluteMs ?? 0,
                changedAt: now,
                syncedOffsetMs: existing?.syncedOffsetMs,
                syncedAt: existing?.syncedAt,
                finishedAt: now,
                revision: (existing?.revision ?? 0) + 1,
                dirty: true
            )
            try progress.save(db)
            try Self.enqueue(
                db,
                bookRatingKey: bookRatingKey,
                kind: .finished,
                absoluteMs: progress.absoluteMs,
                at: now,
                revision: progress.revision
            )
        }
    }

    /// Puts a book back to the beginning and unfinishes it.
    ///
    /// The counterpart to `markFinished`, and needed for the same reason: a book
    /// can be finished without being played to its end — abandoned, or listened
    /// to elsewhere — and one can be started again after it was.
    ///
    /// A revision bump and a queued change like any other, so the server hears
    /// about it and another device does not push the old position back. Setting
    /// the row to zero locally and staying quiet would be undone by the next
    /// sync, which is the failure this whole outbox exists to prevent.
    public func resetProgress(bookRatingKey: String, at now: Date = Date()) throws {
        try database.writer.write { db in
            let existing = try ProgressRecord.fetchOne(db, key: bookRatingKey)
            let progress = ProgressRecord(
                bookRatingKey: bookRatingKey,
                absoluteMs: 0,
                changedAt: now,
                syncedOffsetMs: existing?.syncedOffsetMs,
                syncedAt: existing?.syncedAt,
                // Cleared, not left: a book at zero that still says it was
                // finished is a book the library will keep filing under done.
                finishedAt: nil,
                revision: (existing?.revision ?? 0) + 1,
                dirty: true
            )
            try progress.save(db)

            // A book that *was* finished has to be unfinished on the server too.
            //
            // Plex records completion per track, and a position of zero does not
            // undo it: every track stays scrobbled, so the book still reads as
            // fully played there while reading as unstarted here. Queueing
            // `.unfinished` unscrobbles them, which is what puts it back to zero
            // on both sides.
            //
            // Only when it was finished. Restarting a book somebody is halfway
            // through has nothing to unscrobble, and asking Plex to unscrobble
            // tracks it never marked is a request per track for nothing.
            try Self.enqueue(
                db,
                bookRatingKey: bookRatingKey,
                kind: existing?.finishedAt == nil ? .position : .unfinished,
                absoluteMs: 0,
                at: now,
                revision: progress.revision
            )
        }
    }

    public func progress(bookRatingKey: String) throws -> ProgressRecord? {
        try database.writer.read { db in
            try ProgressRecord.fetchOne(db, key: bookRatingKey)
        }
    }

    // MARK: - Outbox

    /// Inserts or replaces the pending entry for this book and kind.
    ///
    /// The unique index on (book_rating_key, kind) does the coalescing: a
    /// two-hour offline session leaves one row holding the final position, not
    /// seven hundred rows describing the journey. `attempts` resets because the
    /// payload is new — a previously failing position is not evidence that this
    /// one will fail.
    /// Queues a change for Plex.
    ///
    /// `internal`, not `private`: `CloudSyncStore` calls it when a position
    /// arrives from another device, so the server hears about it too. Both types
    /// are in this module and the outbox is the one way in.
    static func enqueue(
        _ db: Database,
        bookRatingKey: String,
        kind: OutboxEntry.Kind,
        absoluteMs: Int,
        at now: Date,
        revision: Int
    ) throws {
        // The opposite instruction, if one is waiting, is dropped.
        //
        // The queue coalesces per kind, so `finished` and `unfinished` are
        // separate rows and both could sit there at once — which is what
        // happens the moment somebody presses the new tick twice before the
        // outbox drains.
        //
        // Draining both is not wrong in the end: they go oldest-first, so the
        // later one wins. But it scrobbles every track and then unscrobbles
        // every track — two requests per track to reach the state one of them
        // describes — and a drain interrupted between the two leaves the book
        // finished on the server when somebody said it was not.
        //
        // They contradict each other, so the newer one replaces the older.
        if let opposite = kind.opposite {
            try OutboxRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .filter(Column("kind") == opposite.rawValue)
                .deleteAll(db)
        }

        let existing = try OutboxRecord
            .filter(Column("book_rating_key") == bookRatingKey)
            .filter(Column("kind") == kind.rawValue)
            .fetchOne(db)

        let record = OutboxRecord(
            entry: OutboxEntry(
                id: existing.flatMap { UUID(uuidString: $0.id) } ?? UUID(),
                bookRatingKey: bookRatingKey,
                kind: kind,
                absoluteMs: absoluteMs,
                recordedAt: now,
                revision: revision,
                attempts: 0,
                lastError: nil
            )
        )
        try record.save(db)
    }

    /// Entries ready to send, oldest first, skipping ones in backoff.
    ///
    /// Backoff is exponential on `attempts` and capped: something that has
    /// failed eleven times is not going to succeed on the twelfth, and hammering
    /// a server that is refusing us is worse than waiting.
    public func pendingOutbox(limit: Int = 50, now: Date = Date()) throws -> [OutboxEntry] {
        try database.writer.read { db in
            try OutboxRecord
                .order(Column("recorded_at").asc)
                .fetchAll(db)
                .filter { record in
                    guard record.attempts > 0 else { return true }
                    let delay = min(pow(2.0, Double(record.attempts)), 3600)
                    return record.recordedAt.addingTimeInterval(delay) <= now
                }
                .prefix(limit)
                .compactMap(\.entry)
        }
    }

    /// Called after a successful push. Clears the outbox row and records what
    /// was synced, which is what lets reconnect tell a local change from a
    /// value we merely read.
    public func markSynced(
        bookRatingKey: String,
        kind: OutboxEntry.Kind,
        absoluteMs: Int,
        at now: Date = Date()
    ) throws {
        try database.writer.write { db in
            try OutboxRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .filter(Column("kind") == kind.rawValue)
                .deleteAll(db)

            if var progress = try ProgressRecord.fetchOne(db, key: bookRatingKey) {
                progress.syncedOffsetMs = absoluteMs
                progress.syncedAt = now
                // Only clean if nothing changed while the push was in flight.
                progress.dirty = progress.absoluteMs != absoluteMs
                try progress.save(db)
            }
        }
    }

    public func markFailed(entry: OutboxEntry, error: String) throws {
        try database.writer.write { db in
            guard var record = try OutboxRecord.fetchOne(db, key: entry.id.uuidString) else { return }
            record.attempts += 1
            record.lastError = error
            try record.save(db)
        }
    }

    public func outboxDepth() throws -> Int {
        try database.writer.read { db in try OutboxRecord.fetchCount(db) }
    }

    // MARK: - Reconciliation

    /// Compares the local position against what the server reports.
    ///
    /// The decision itself lives in `Reconciliation.resolve` so it can be tested
    /// without a database; this only supplies the four timestamps it needs.
    public func reconcile(
        bookRatingKey: String,
        remoteMs: Int?,
        remoteChangedAt: Date?
    ) throws -> Reconciliation {
        let local = try progress(bookRatingKey: bookRatingKey)
        return Reconciliation.resolve(
            localMs: local?.absoluteMs,
            localChangedAt: local?.changedAt,
            remoteMs: remoteMs,
            remoteChangedAt: remoteChangedAt,
            lastSyncedAt: local?.syncedAt
        )
    }

    /// Applies a resolved remote position without marking it dirty — it came
    /// from the server, so pushing it back would be a pointless round trip.
    public func adoptRemote(
        bookRatingKey: String,
        absoluteMs: Int,
        at now: Date = Date()
    ) throws {
        try database.writer.write { db in
            let existing = try ProgressRecord.fetchOne(db, key: bookRatingKey)
            let progress = ProgressRecord(
                bookRatingKey: bookRatingKey,
                absoluteMs: absoluteMs,
                changedAt: now,
                syncedOffsetMs: absoluteMs,
                syncedAt: now,
                finishedAt: existing?.finishedAt,
                revision: (existing?.revision ?? 0) + 1,
                dirty: false
            )
            try progress.save(db)
            try OutboxRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .filter(Column("kind") == OutboxEntry.Kind.position.rawValue)
                .deleteAll(db)
        }
    }

    // MARK: - Per-book settings

    /// Playback rate remembered for one book, or nil if it has never been set.
    public func rate(bookRatingKey: String) throws -> Double? {
        try database.writer.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT rate FROM book_settings WHERE book_rating_key = ?",
                arguments: [bookRatingKey]
            )
        }
    }

    /// Remembers a rate, bumping the revision so CloudKit picks it up.
    ///
    /// Written as an upsert rather than fetch-modify-save: two screens can set a
    /// rate for the same book, and the last write should win without either
    /// needing to have read first.
    public func setRate(_ rate: Double, bookRatingKey: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO book_settings (book_rating_key, rate, revision, dirty)
                    VALUES (?, ?, 1, 1)
                    ON CONFLICT(book_rating_key) DO UPDATE SET
                        rate = excluded.rate,
                        revision = revision + 1,
                        dirty = 1
                    """,
                arguments: [bookRatingKey, rate]
            )
        }
    }

    // MARK: - Bookmarks

    public func addBookmark(
        bookRatingKey: String,
        absoluteMs: Int,
        label: String?,
        at now: Date = Date()
    ) throws -> BookmarkRecord {
        let record = BookmarkRecord(
            id: UUID().uuidString,
            bookRatingKey: bookRatingKey,
            absoluteMs: absoluteMs,
            label: label,
            createdAt: now,
            revision: 1,
            dirty: true,
            deletedAt: nil
        )
        try database.writer.write { db in
            try record.insert(db)
        }
        return record
    }

    /// Soft delete. CloudKit needs a tombstone to propagate the deletion; a hard
    /// DELETE would let any device that had not synced yet resurrect the row.
    public func deleteBookmark(id: String, at now: Date = Date()) throws {
        try database.writer.write { db in
            guard var record = try BookmarkRecord.fetchOne(db, key: id) else { return }
            record.deletedAt = now
            record.revision += 1
            record.dirty = true
            try record.save(db)
        }
    }

    public func bookmarks(bookRatingKey: String) throws -> [BookmarkRecord] {
        try database.writer.read { db in
            try BookmarkRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .filter(Column("deleted_at") == nil)
                .order(Column("absolute_ms").asc)
                .fetchAll(db)
        }
    }
}
