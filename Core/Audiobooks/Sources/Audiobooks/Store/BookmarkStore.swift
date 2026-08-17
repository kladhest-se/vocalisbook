import Foundation
import GRDB

/// Bookmarks: a labelled position in a book.
///
/// The table and its tombstone column have existed since the first migration and
/// nothing wrote to them. Plex cannot hold these — it has no concept of a
/// bookmark, only a single position per item — so they are local, and marked
/// `dirty` for the CloudKit sync engine to pick up when that exists.
public struct BookmarkStore: Sendable {
    private let database: AudiobookDatabase

    public init(database: AudiobookDatabase) {
        self.database = database
    }

    /// Adds a bookmark at a position.
    ///
    /// A label is optional. An unlabelled bookmark is still useful — "somewhere
    /// around here" is the common case while listening, and forcing a name at
    /// the moment of pressing the button is how a feature stops being used.
    @discardableResult
    public func add(
        bookRatingKey: String,
        absoluteMs: Int,
        label: String? = nil,
        now: Date = Date()
    ) throws -> BookmarkRecord {
        let record = BookmarkRecord(
            id: UUID().uuidString,
            bookRatingKey: bookRatingKey,
            absoluteMs: max(0, absoluteMs),
            label: label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            createdAt: now,
            revision: 1,
            dirty: true,
            deletedAt: nil
        )
        try database.writer.write { db in try record.insert(db) }
        return record
    }

    /// Renames one. Bumps the revision so a sync knows this side is newer.
    public func setLabel(_ label: String?, id: String) throws {
        try database.writer.write { db in
            guard var record = try BookmarkRecord.fetchOne(db, key: id) else { return }
            record.label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            record.revision += 1
            record.dirty = true
            try record.update(db)
        }
    }

    /// Soft delete.
    ///
    /// A hard `DELETE` would be resurrected by the next device to sync, which
    /// has never heard of the deletion and still holds the row. The tombstone is
    /// what carries "this is gone" across.
    public func delete(id: String, now: Date = Date()) throws {
        try database.writer.write { db in
            guard var record = try BookmarkRecord.fetchOne(db, key: id) else { return }
            record.deletedAt = now
            record.revision += 1
            record.dirty = true
            try record.update(db)
        }
    }

    /// Bookmarks for a book, in the order they occur in it.
    ///
    /// Position order rather than creation order: this is a list you scan while
    /// looking for a place in a book, not a history of when you pressed a button.
    public func bookmarks(bookRatingKey: String) throws -> [BookmarkRecord] {
        try database.writer.read { db in
            try BookmarkRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .filter(Column("deleted_at") == nil)
                .order(Column("absolute_ms").asc)
                .fetchAll(db)
        }
    }

    /// Every bookmark, newest first, for a list across the whole library.
    public func recent(limit: Int = 100) throws -> [BookmarkRecord] {
        try database.writer.read { db in
            try BookmarkRecord
                .filter(Column("deleted_at") == nil)
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func count(bookRatingKey: String) throws -> Int {
        try database.writer.read { db in
            try BookmarkRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .filter(Column("deleted_at") == nil)
                .fetchCount(db)
        }
    }

    /// Everything a sync would need to push.
    public func dirty() throws -> [BookmarkRecord] {
        try database.writer.read { db in
            try BookmarkRecord.filter(Column("dirty") == true).fetchAll(db)
        }
    }

    /// Clears the dirty flag after a successful push, unless the row changed
    /// again in the meantime — which is why the revision is compared rather than
    /// the flag simply being cleared.
    public func markSynced(id: String, revision: Int) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE bookmark SET dirty = 0 WHERE id = ? AND revision = ?",
                arguments: [id, revision]
            )
        }
    }
}

extension String {
    /// An empty label and no label are the same thing, and storing "" makes
    /// every read site check for both.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
