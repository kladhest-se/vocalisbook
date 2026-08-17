import Foundation
import Testing
@testable import Audiobooks

@Suite("Bookmarks")
struct BookmarkStoreTests {

    private func makeStore() throws -> (BookmarkStore, AudiobookDatabase) {
        let db = try AudiobookDatabase.inMemory()
        return (BookmarkStore(database: db), db)
    }

    @Test("Bookmarks come back in the order they occur in the book")
    func positionOrder() throws {
        // Not creation order: this is a list you scan for a place in a book, not
        // a history of when the button was pressed.
        let (store, _) = try makeStore()
        try store.add(bookRatingKey: "900", absoluteMs: 3_000_000, label: "later")
        try store.add(bookRatingKey: "900", absoluteMs: 60_000, label: "earlier")

        let bookmarks = try store.bookmarks(bookRatingKey: "900")
        #expect(bookmarks.map(\.label) == ["earlier", "later"])
    }

    @Test("An unlabelled bookmark is allowed, and blank is the same as none")
    func blankLabels() throws {
        // Forcing a name at the moment of pressing the button is how a feature
        // stops being used.
        let (store, _) = try makeStore()
        try store.add(bookRatingKey: "900", absoluteMs: 1_000)
        try store.add(bookRatingKey: "900", absoluteMs: 2_000, label: "   ")

        let bookmarks = try store.bookmarks(bookRatingKey: "900")
        #expect(bookmarks.count == 2)
        #expect(bookmarks.allSatisfy { $0.label == nil })
    }

    @Test("Deleting leaves a tombstone rather than removing the row")
    func softDelete() throws {
        // A hard DELETE is resurrected by the next device to sync, which has
        // never heard of the deletion and still holds the row.
        let (store, db) = try makeStore()
        let bookmark = try store.add(bookRatingKey: "900", absoluteMs: 1_000, label: "gone")
        try store.delete(id: bookmark.id)

        let visible = try store.bookmarks(bookRatingKey: "900")
        #expect(visible.isEmpty)

        let row = try db.writer.read { conn in
            try BookmarkRecord.fetchOne(conn, key: bookmark.id)
        }
        #expect(row?.deletedAt != nil, "the row is still there, marked gone")
        #expect(row?.dirty == true, "and queued for the next sync")
    }

    @Test("A negative position clamps rather than storing a nonsense place")
    func negativeClamps() throws {
        let (store, _) = try makeStore()
        try store.add(bookRatingKey: "900", absoluteMs: -5_000)
        let bookmarks = try store.bookmarks(bookRatingKey: "900")
        #expect(bookmarks.first?.absoluteMs == 0)
    }

    @Test("Renaming bumps the revision so a sync knows this side is newer")
    func renameBumpsRevision() throws {
        let (store, _) = try makeStore()
        let bookmark = try store.add(bookRatingKey: "900", absoluteMs: 1_000, label: "first")
        try store.setLabel("second", id: bookmark.id)

        let updated = try store.bookmarks(bookRatingKey: "900").first
        #expect(updated?.label == "second")
        #expect(updated?.revision == 2)
    }

    @Test("A row changed since the push stays dirty")
    func markSyncedRespectsRevision() throws {
        // Otherwise an edit made while the push was in flight would be dropped:
        // the flag would clear and the newer text would never be sent.
        let (store, _) = try makeStore()
        let bookmark = try store.add(bookRatingKey: "900", absoluteMs: 1_000, label: "first")

        try store.setLabel("edited while pushing", id: bookmark.id)
        try store.markSynced(id: bookmark.id, revision: bookmark.revision)

        let dirty = try store.dirty()
        #expect(dirty.count == 1)
        #expect(dirty.first?.label == "edited while pushing")
    }

    @Test("Counts and recents ignore the deleted")
    func countsIgnoreTombstones() throws {
        let (store, _) = try makeStore()
        try store.add(bookRatingKey: "900", absoluteMs: 1_000)
        let second = try store.add(bookRatingKey: "900", absoluteMs: 2_000)
        try store.add(bookRatingKey: "901", absoluteMs: 3_000)
        try store.delete(id: second.id)

        let count = try store.count(bookRatingKey: "900")
        #expect(count == 1)
        let recent = try store.recent()
        #expect(recent.count == 2)
    }
}
