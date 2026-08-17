import Foundation
import GRDB

/// The local half of iCloud sync.
///
/// Collects what has changed here, applies what changed elsewhere, and decides
/// which wins. Knows nothing about CloudKit — a platform package drives
/// `CKSyncEngine` and speaks to this in `CloudRecord`s, the same seam
/// `HTTPClient` draws for the network.
///
/// **The conflict rule is the revision number, and nothing else.** Every store
/// that edits a syncable row bumps `revision` and sets `dirty`; those columns
/// have been in the schema since the first migration and until now nothing read
/// them. A higher revision wins. Timestamps are not used: two devices with
/// clocks a minute apart produce a merge that depends on whose clock is fast,
/// and the failure is silent and unreproducible.
public struct CloudSyncStore: Sendable {

    private let database: AudiobookDatabase
    private let bookmarks: BookmarkStore

    public init(database: AudiobookDatabase) {
        self.database = database
        // Reused rather than reimplemented. `BookmarkStore` already knows how to
        // list dirty rows and how to clear the flag only when the revision still
        // matches; a second copy of that SQL here would be two implementations
        // of one rule, and they would not stay the same.
        self.bookmarks = BookmarkStore(database: database)
    }

    // MARK: - Outgoing

    /// Everything edited here and not yet acknowledged.
    ///
    /// Tombstones included: a row deleted locally has to travel, or every other
    /// device still holds it and pushes it back.
    public func pendingChanges(limit: Int = 200) throws -> [CloudRecord] {
        // Resolved to identities before they travel.
        //
        // A bookmark's own id is a UUID and already portable, but the field
        // naming its book was a rating key — so a bookmark arriving on another
        // server attached itself to whatever book happened to hold that number
        // there. The id was fine and the contents were not.
        let dirtyBookmarks = try bookmarks.dirty().prefix(limit)
        var records = try database.writer.read { db in
            try dirtyBookmarks.map { bookmark in
                Self.record(
                    for: bookmark,
                    identity: try Self.identity(forBook: bookmark.bookRatingKey, db: db)
                )
            }
        }

        let remaining = max(0, limit - records.count)
        guard remaining > 0 else { return records }

        try database.writer.read { db in
            // Positions first of the four.
            //
            // This is the one somebody is waiting for: it decides whether the
            // other device lists the book at all, and whether it opens at the
            // right minute. Bookmarks and speeds can wait a batch; history
            // certainly can.
            // Joined to `book` for the identity, which is what the record is
            // keyed by: a rating key means nothing on another server.
            //
            // An inner join, so a position for a book that is not cached is not
            // sent. It cannot be — there is nothing to name it with — and it
            // stays dirty, so it goes as soon as the book arrives. In practice a
            // book is cached long before it is played.
            let positions = try Row.fetchAll(db, sql: """
                SELECT book.identity_key AS identity_key,
                       progress.absolute_ms AS absolute_ms,
                       progress.changed_at AS changed_at,
                       progress.finished_at AS finished_at,
                       progress.revision AS revision
                FROM progress
                JOIN book ON book.rating_key = progress.book_rating_key
                WHERE progress.cloud_dirty = 1 AND book.identity_key IS NOT NULL
                LIMIT ?
                """, arguments: [remaining])
            records.append(contentsOf: positions.map(Self.progressRecord(from:)))

            let afterProgress = max(0, limit - records.count)
            guard afterProgress > 0 else { return }

            // Joined for the identity, like progress. A rating key means
            // nothing on another server, so a speed that travelled under one
            // arrived for whatever book happened to hold that number there.
            let settings = try Row.fetchAll(db, sql: """
                SELECT book.identity_key AS identity_key,
                       book_settings.book_rating_key AS book_rating_key,
                       book_settings.rate AS rate,
                       book_settings.revision AS revision
                FROM book_settings
                JOIN book ON book.rating_key = book_settings.book_rating_key
                WHERE book_settings.dirty = 1 AND book.identity_key IS NOT NULL
                LIMIT ?
                """, arguments: [afterProgress])
            records.append(contentsOf: settings.map(Self.settingsRecord(from:)))

            let left = max(0, limit - records.count)
            guard left > 0 else { return }

            // Sessions last of the three.
            //
            // Listening history is append-only and by far the most numerous —
            // one row per stretch of listening, for ever. Putting it after the
            // others means a device with a thousand unsynced sessions still gets
            // its bookmarks and speeds across in the first batch, rather than
            // spending every batch on history nobody is waiting for.
            let sessions = try Row.fetchAll(db, sql: """
                SELECT listening_session.id AS id,
                       book.identity_key AS identity_key,
                       listening_session.book_rating_key AS book_rating_key,
                       listening_session.started_at AS started_at,
                       listening_session.ended_at AS ended_at,
                       listening_session.start_ms AS start_ms,
                       listening_session.end_ms AS end_ms,
                       listening_session.rate AS rate,
                       listening_session.revision AS revision
                FROM listening_session
                JOIN book ON book.rating_key = listening_session.book_rating_key
                WHERE listening_session.dirty = 1 AND book.identity_key IS NOT NULL
                LIMIT ?
                """, arguments: [left])
            records.append(contentsOf: sessions.map(Self.sessionRecord(from:)))
        }

        return records
    }

    /// Clears `dirty` for rows the server has accepted.
    ///
    /// Only when the revision still matches. An edit made while the push was in
    /// flight has a higher revision, and clearing its flag would strand that
    /// edit on this device for ever — the row would be different everywhere and
    /// never offered again.
    public func markPushed(_ records: [CloudRecord]) throws {
        for record in records where record.kind == .bookmark {
            try bookmarks.markSynced(id: record.id, revision: record.revision)
        }

        try database.writer.write { db in
            for record in records where record.kind == .bookSettings {
                // Back through `book`, like progress: the record names an
                // identity and the row is keyed by a rating key. Matching the id
                // against `book_rating_key` directly would clear nothing and the
                // speed would be pushed again on every sync, for ever.
                try db.execute(
                    sql: """
                        UPDATE book_settings SET dirty = 0
                        WHERE revision = ? AND book_rating_key IN (
                            SELECT rating_key FROM book WHERE identity_key = ?
                        )
                        """,
                    arguments: [record.revision, record.id]
                )
            }
            for record in records where record.kind == .progress {
                // `cloud_dirty` only. `dirty` belongs to Plex and is cleared
                // when Plex takes the position; clearing it here would mean a
                // position that reached iCloud never reached the server.
                //
                // Matched on revision, so a position changed again while the
                // push was in flight stays dirty and goes out next time.
                // Back through `book`, since the record names an identity and
                // the row is keyed by a rating key.
                try db.execute(
                    sql: """
                        UPDATE progress SET cloud_dirty = 0
                        WHERE revision = ? AND book_rating_key IN (
                            SELECT rating_key FROM book WHERE identity_key = ?
                        )
                        """,
                    arguments: [record.revision, record.id]
                )
            }
            for record in records where record.kind == .listeningSession {
                try db.execute(
                    sql: """
                        UPDATE listening_session SET dirty = 0
                        WHERE id = ? AND revision = ?
                        """,
                    arguments: [record.id, record.revision]
                )
            }
        }
    }

    // MARK: - Incoming

    public struct ApplyResult: Sendable, Equatable {
        public var applied = 0
        /// Records the local side already has a newer version of. They stay
        /// dirty and go out on the next push, which is how the other device
        /// learns it was behind.
        public var rejected = 0
    }

    @discardableResult
    public func apply(_ records: [CloudRecord]) throws -> ApplyResult {
        var result = ApplyResult()

        try database.writer.write { db in
            for record in records {
                let accepted: Bool
                switch record.kind {
                case .progress: accepted = try applyProgress(record, db: db)
                case .bookmark: accepted = try applyBookmark(record, db: db)
                case .bookSettings: accepted = try applySettings(record, db: db)
                case .listeningSession: accepted = try applySession(record, db: db)
                }
                if accepted { result.applied += 1 } else { result.rejected += 1 }
            }

            // Swept here rather than on a timer: this is the only place rows are
            // added, so it is the only place the table can grow.
            try Self.pruneInbox(db, before: Date().addingTimeInterval(-Self.inboxLifetime))
        }

        return result
    }

    /// How long a held position waits for its book. Thirty days.
    static let inboxLifetime: TimeInterval = 30 * 24 * 60 * 60

    private func applyBookmark(_ record: CloudRecord, db: Database) throws -> Bool {
        let existing = try BookmarkRecord.fetchOne(db, key: record.id)

        // A tie goes to the remote. Equal revisions mean the same generation of
        // an edit, and picking the local side there means two devices can sit
        // for ever each convinced the other is out of date.
        if let existing, existing.revision > record.revision { return false }

        // The identity first, and the rating key only as what a device on an
        // older version would have sent. A rating key from another server names
        // whatever book happens to hold that number here, which is worse than
        // not attaching the bookmark at all.
        let namedBook = try record.fields["bookIdentity"]?.stringValue
            .flatMap { try Self.localBook(for: $0, db: db) }
            ?? record.fields["bookRatingKey"]?.stringValue

        let bookmark = BookmarkRecord(
            id: record.id,
            bookRatingKey: namedBook ?? existing?.bookRatingKey ?? "",
            absoluteMs: record.fields["absoluteMs"]?.intValue ?? existing?.absoluteMs ?? 0,
            label: record.fields["label"]?.stringValue ?? existing?.label,
            createdAt: record.fields["createdAt"]?.dateValue ?? existing?.createdAt ?? Date(),
            revision: record.revision,
            // Applying a remote change must never mark the row dirty. It would
            // be pushed straight back, and two devices would trade the same
            // record for ever.
            dirty: false,
            deletedAt: record.isDeleted
                ? (record.fields["deletedAt"]?.dateValue ?? Date())
                : nil
        )
        try bookmark.save(db)
        return true
    }

    /// A position from another device.
    ///
    /// Two things happen, and the second is what keeps Plex honest.
    ///
    /// The row is written with `cloud_dirty = 0` — it came from iCloud, so
    /// sending it back would be an echo — and `dirty = 1`, because Plex has *not*
    /// seen it. An outbox entry goes with it, so the next drain tells the server
    /// and every other Plex client agrees.
    ///
    /// Without that second half this would be a private conversation between
    /// VocalisBook installs, and somebody opening Plexamp would find their place
    /// where they left it two devices ago.
    private func applyProgress(_ record: CloudRecord, db: Database) throws -> Bool {
        guard let absoluteMs = record.fields["absoluteMs"]?.intValue,
              let changedAt = record.fields["changedAt"]?.dateValue
        else { return false }

        let finishedAt = record.fields["finishedAt"]?.dateValue

        // The identity has to become a rating key before anything can be
        // written, because that is what `progress` is keyed by.
        //
        // Two ways it can be one. A record made by a client on this contract
        // names an identity, and `book.identity_key` resolves it. A record made
        // before this change names a rating key directly — those are still out
        // there in the container and there is no migration that can rewrite
        // somebody else's device, so a raw rating key is accepted as itself.
        guard let bookRatingKey = try Self.localBook(for: record.id, db: db) else {
            // No book here yet. Held rather than dropped: nothing will send it
            // again, because the sending device believes it was delivered.
            try holdForLater(
                record, absoluteMs: absoluteMs,
                changedAt: changedAt, finishedAt: finishedAt, db: db
            )
            return true
        }

        return try writeProgress(
            bookRatingKey: bookRatingKey,
            absoluteMs: absoluteMs,
            changedAt: changedAt,
            finishedAt: finishedAt,
            revision: record.revision,
            db: db
        )
    }

    /// Writes an arriving position, if it is newer than what is here.
    ///
    /// Compared by time, which is the same clock on every device. A revision is
    /// a per-device counter and orders nothing across them.
    private func writeProgress(
        bookRatingKey: String,
        absoluteMs: Int,
        changedAt: Date,
        finishedAt: Date?,
        revision: Int,
        db: Database
    ) throws -> Bool {
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT changed_at, revision FROM progress WHERE book_rating_key = ?",
            arguments: [bookRatingKey]
        )
        if let existing, let localChangedAt = existing["changed_at"] as Date? {
            if localChangedAt > changedAt { return false }
            if localChangedAt == changedAt,
               let localRevision = existing["revision"] as Int?,
               localRevision >= revision {
                return false
            }
        }

        try db.execute(sql: """
            INSERT INTO progress
                (book_rating_key, absolute_ms, changed_at, finished_at,
                 revision, dirty, cloud_dirty)
            VALUES (?, ?, ?, ?, ?, 1, 0)
            ON CONFLICT(book_rating_key) DO UPDATE SET
                absolute_ms = excluded.absolute_ms,
                changed_at = excluded.changed_at,
                finished_at = excluded.finished_at,
                revision = excluded.revision,
                dirty = 1,
                cloud_dirty = 0
            """, arguments: [bookRatingKey, absoluteMs, changedAt, finishedAt, revision])

        // Plex is told as well, so other Plex clients stay in step.
        try SyncStore.enqueue(
            db,
            bookRatingKey: bookRatingKey,
            kind: finishedAt == nil ? .position : .finished,
            absoluteMs: absoluteMs,
            at: changedAt,
            revision: revision
        )
        return true
    }

    /// Keeps a position for a book this device has not cached.
    ///
    /// Newest wins here too, so a book that changes on two other devices before
    /// this one catches up ends up with the right position rather than whichever
    /// arrived last.
    private func holdForLater(
        _ record: CloudRecord,
        absoluteMs: Int,
        changedAt: Date,
        finishedAt: Date?,
        db: Database
    ) throws {
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT changed_at FROM cloud_progress WHERE identity_key = ?",
            arguments: [record.id]
        )
        if let existing, let held = existing["changed_at"] as Date?, held > changedAt {
            return
        }

        try db.execute(sql: """
            INSERT INTO cloud_progress
                (identity_key, absolute_ms, changed_at, finished_at, revision)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(identity_key) DO UPDATE SET
                absolute_ms = excluded.absolute_ms,
                changed_at = excluded.changed_at,
                finished_at = excluded.finished_at,
                revision = excluded.revision
            """, arguments: [
                record.id, absoluteMs, changedAt, finishedAt, record.revision,
            ])
    }

    private func applySettings(_ record: CloudRecord, db: Database) throws -> Bool {
        // The id names a book by identity now, so it has to become this device's
        // rating key before anything is read or written. A settings row keyed by
        // another server's number is a playback speed applied to the wrong book.
        //
        // Not held for later like a position: a speed is a preference, and one
        // for a book this device does not have is worth less than the row it
        // would take to remember it.
        guard let bookRatingKey = try Self.localBook(for: record.id, db: db) else {
            return false
        }

        let existing = try Row.fetchOne(
            db,
            sql: "SELECT revision FROM book_settings WHERE book_rating_key = ?",
            arguments: [bookRatingKey]
        )
        if let existing, let revision = existing["revision"] as Int?, revision > record.revision {
            return false
        }

        try db.execute(sql: """
            INSERT INTO book_settings (book_rating_key, rate, revision, dirty)
            VALUES (?, ?, ?, 0)
            ON CONFLICT(book_rating_key) DO UPDATE SET
                rate = excluded.rate,
                revision = excluded.revision,
                dirty = 0
            """, arguments: [
                bookRatingKey,
                record.fields["rate"]?.doubleValue,
                record.revision,
            ])
        return true
    }

    /// A session, which is closed once and never edited again.
    ///
    /// The revision rule still applies: `end` bumps it, so a session begun on
    /// one device and ended there arrives as revision 2 and supersedes the
    /// revision 1 another device may already hold.
    private func applySession(_ record: CloudRecord, db: Database) throws -> Bool {
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT revision FROM listening_session WHERE id = ?",
            arguments: [record.id]
        )
        if let existing, let revision = existing["revision"] as Int?, revision > record.revision {
            return false
        }

        try db.execute(sql: """
            INSERT INTO listening_session
                (id, book_rating_key, started_at, ended_at, start_ms, end_ms, rate, revision, dirty)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET
                book_rating_key = excluded.book_rating_key,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                start_ms = excluded.start_ms,
                end_ms = excluded.end_ms,
                rate = excluded.rate,
                revision = excluded.revision,
                dirty = 0
            """, arguments: [
                record.id,
                // Identity first, rating key as what an older device would have
                // sent — a rating key from another server names whatever book
                // happens to hold that number here.
                (try record.fields["bookIdentity"]?.stringValue
                    .flatMap { try Self.localBook(for: $0, db: db) })
                    ?? record.fields["bookRatingKey"]?.stringValue ?? "",
                record.fields["startedAt"]?.dateValue ?? Date(),
                record.fields["endedAt"]?.dateValue,
                record.fields["startMs"]?.intValue ?? 0,
                record.fields["endMs"]?.intValue,
                record.fields["rate"]?.doubleValue,
                record.revision,
            ])
        return true
    }

    /// Forgets held positions nobody has claimed in a long time.
    ///
    /// A record for a book this device has not cached waits in `cloud_progress`
    /// until that book arrives — which is right when the library is still
    /// syncing, and never when the book lives on a server this device does not
    /// use, or has since been deleted from Plex. Those rows have nothing to wait
    /// for and would sit there for the life of the install.
    ///
    /// A month, because the case this exists for is a device catching up after
    /// being away, and being away for a month is a holiday rather than an error.
    /// Anything older is waiting for something that is not coming.
    static func pruneInbox(_ db: Database, before cutoff: Date) throws {
        try db.execute(
            sql: "DELETE FROM cloud_progress WHERE changed_at < ?",
            arguments: [cutoff]
        )
    }

    /// Turns a book identity into this device's rating key.
    ///
    /// Everything that arrives from iCloud names a book by identity, and every
    /// table here is keyed by rating key, so this is the crossing point for all
    /// of them.
    ///
    /// Three ways it can be one, in order:
    ///
    /// - The identity a book was cached with, which is the normal case.
    /// - The id *as* a rating key. Records made before identities existed are
    ///   still in the container and no migration can rewrite another device's.
    /// - A `plex:<server>:<ratingKey>` id matched on the rating key it names.
    ///   One device refreshes and holds `spokenmeta:…` while another still sends
    ///   the per-server form for the same book; both are on the same server, so
    ///   the rating key agrees. Only that form, and only that key — this cannot
    ///   make two servers agree and does not pretend to.
    static func localBook(for identity: String, db: Database) throws -> String? {
        if let resolved = try Row.fetchOne(
            db,
            sql: "SELECT rating_key FROM book WHERE identity_key = ?",
            arguments: [identity]
        )?["rating_key"] as String? {
            return resolved
        }

        if let legacy = try Row.fetchOne(
            db,
            sql: "SELECT rating_key FROM book WHERE rating_key = ?",
            arguments: [identity]
        )?["rating_key"] as String? {
            return legacy
        }

        guard identity.hasPrefix("plex:") else { return nil }
        let parts = identity.split(separator: ":", maxSplits: 2)
        guard parts.count == 3 else { return nil }

        return try Row.fetchOne(
            db,
            sql: "SELECT rating_key FROM book WHERE rating_key = ?",
            arguments: [String(parts[2])]
        )?["rating_key"] as String?
    }

    /// The identity a book travels under, or nil when it is not cached.
    static func identity(forBook ratingKey: String, db: Database) throws -> String? {
        try Row.fetchOne(
            db,
            sql: "SELECT identity_key FROM book WHERE rating_key = ?",
            arguments: [ratingKey]
        )?["identity_key"] as String?
    }

    // MARK: - Mapping

    static func record(for bookmark: BookmarkRecord, identity: String?) -> CloudRecord {
        var fields: [String: CloudValue] = [
            // Both, for now. A device on this version reads `bookIdentity`; one
            // on an older version still expects `bookRatingKey`, and dropping it
            // would make this device's bookmarks unreadable to them.
            "bookRatingKey": .string(bookmark.bookRatingKey),
            "absoluteMs": .int(bookmark.absoluteMs),
            "createdAt": .date(bookmark.createdAt),
        ]
        if let identity { fields["bookIdentity"] = .string(identity) }
        if let label = bookmark.label { fields["label"] = .string(label) }
        if let deletedAt = bookmark.deletedAt { fields["deletedAt"] = .date(deletedAt) }

        return CloudRecord(
            kind: .bookmark,
            id: bookmark.id,
            revision: bookmark.revision,
            isDeleted: bookmark.deletedAt != nil,
            fields: fields
        )
    }

    static func sessionRecord(from row: Row) -> CloudRecord {
        var fields: [String: CloudValue] = [
            // Both, for now. `bookIdentity` is what a device on this version
            // reads; `bookRatingKey` is what one on an older version still
            // expects, and dropping it would make this device's history
            // unreadable to them.
            "bookIdentity": .string(row["identity_key"]),
            "bookRatingKey": .string(row["book_rating_key"]),
            "startedAt": .date(row["started_at"]),
            "startMs": .int(row["start_ms"]),
        ]
        if let endedAt = row["ended_at"] as Date? { fields["endedAt"] = .date(endedAt) }
        if let endMs = row["end_ms"] as Int? { fields["endMs"] = .int(endMs) }
        if let rate = row["rate"] as Double? { fields["rate"] = .double(rate) }

        return CloudRecord(
            kind: .listeningSession,
            id: row["id"],
            revision: row["revision"],
            fields: fields
        )
    }

    static func progressRecord(from row: Row) -> CloudRecord {
        var fields: [String: CloudValue] = [
            "absoluteMs": .int(row["absolute_ms"]),
            "changedAt": .date(row["changed_at"]),
        ]
        if let finishedAt = row["finished_at"] as Date? {
            fields["finishedAt"] = .date(finishedAt)
        }

        return CloudRecord(
            kind: .progress,
            id: row["identity_key"],
            revision: row["revision"],
            fields: fields
        )
    }

    static func settingsRecord(from row: Row) -> CloudRecord {
        var fields: [String: CloudValue] = [:]
        if let rate = row["rate"] as Double? { fields["rate"] = .double(rate) }

        return CloudRecord(
            kind: .bookSettings,
            id: row["identity_key"],
            revision: row["revision"],
            fields: fields
        )
    }
}
