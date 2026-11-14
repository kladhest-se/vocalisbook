import Foundation
import GRDB
import Testing
@testable import Audiobooks

@Suite("Portable listening backup and merge")
struct ListeningBackupTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let guid = "com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en"

    @Test("Clean and unsynced listening data round-trip and repeat imports are harmless")
    func roundTrip() throws {
        let source = try FollowupFixture()
        try source.cache(fields: ["guid": guid])
        try source.progress.recordPosition(bookRatingKey: "900", absoluteMs: 42000, at: start)
        try source.progress.setRate(1.5, bookRatingKey: "900")
        let bookmark = try BookmarkStore(database: source.db).add(bookRatingKey: "900", absoluteMs: 42000, label: "Favourite", now: start)
        let sessions = SessionStore(database: source.db)
        try sessions.begin(bookRatingKey: "900", atMs: 0, rate: 1.5, sectionID: "A:2", now: start)
        try sessions.end(atMs: 42000, now: start.addingTimeInterval(30))
        let cloud = CloudSyncStore(database: source.db)
        try cloud.markPushed(cloud.pendingChanges())
        let data = try ListeningBackupStore(database: source.db).export(now: start.addingTimeInterval(60))
        let backup = try ListeningBackupStore.inspect(data)
        #expect(backup.books.count == 1 && backup.books[0].bookmarks.count == 1 && backup.books[0].sessions.count == 1)
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-only"))
        let target = try FollowupFixture()
        try target.cache("901", server: "B", fields: ["guid": guid])
        let importer = ListeningBackupStore(database: target.db)
        #expect(try importer.restore(data) == 4)
        #expect(try target.progress.progress(bookRatingKey: "901")?.absoluteMs == 42000)
        #expect(try target.progress.rate(bookRatingKey: "901") == 1.5)
        let restored = try #require(try BookmarkStore(database: target.db).bookmarks(bookRatingKey: "901").first)
        #expect(restored.id == bookmark.id && restored.label == "Favourite" && restored.dirty)
        #expect(try SessionStore(database: target.db).stats(sectionID: "B:2", now: start.addingTimeInterval(60)).allTimeSeconds == 30)
        #expect(try importer.restore(data) == 0)
        #expect(try CloudSyncStore(database: target.db).pendingChanges().count == 4)
        #expect(try target.progress.outboxDepth() == 1)
    }

    @Test("A backup cannot attach to another server's reused rating key")
    func collisionAndDeferredRestore() throws {
        let source = try FollowupFixture()
        try source.cache()
        try source.progress.recordPosition(bookRatingKey: "900", absoluteMs: 123, at: start)
        try BookmarkStore(database: source.db).add(bookRatingKey: "900", absoluteMs: 123)
        try source.db.purgeMetadataCache()
        let data = try ListeningBackupStore(database: source.db).export()
        let target = try FollowupFixture()
        try target.cache(server: "B")
        try ListeningBackupStore(database: target.db).restore(data)
        #expect(try target.progress.progress(bookRatingKey: "900") == nil)
        #expect(try BookmarkStore(database: target.db).count(bookRatingKey: "900") == 0)
        #expect(try target.progress.progress(bookRatingKey: "@identity:plex:A:900")?.absoluteMs == 123)
        try target.db.purgeMetadataCache()
        try target.cache(server: "A")
        #expect(try target.progress.progress(bookRatingKey: "900")?.absoluteMs == 123)
        #expect(try BookmarkStore(database: target.db).count(bookRatingKey: "900") == 1)
    }

    @Test("Newer local edits and deleted bookmarks survive an older backup")
    func mergeKeepsLocal() throws {
        let fixture = try FollowupFixture()
        try fixture.cache()
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        let bookmarks = BookmarkStore(database: fixture.db)
        let bookmark = try bookmarks.add(bookRatingKey: "900", absoluteMs: 100)
        let store = ListeningBackupStore(database: fixture.db), backup = try store.export()
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 200, at: start.addingTimeInterval(60))
        try bookmarks.delete(id: bookmark.id)
        #expect(try store.restore(backup) == 0)
        #expect(try fixture.progress.progress(bookRatingKey: "900")?.absoluteMs == 200)
        #expect(try bookmarks.bookmarks(bookRatingKey: "900").isEmpty)
    }

    @Test("An open backed-up session restores only its last confirmed checkpoint")
    func openSessionUsesCheckpoint() throws {
        let source = try FollowupFixture()
        try source.cache()
        let sessions = SessionStore(database: source.db)
        try sessions.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "A:2", now: start)
        try sessions.checkpoint(atMs: 10000, now: start.addingTimeInterval(10))
        let backup = try ListeningBackupStore(database: source.db).export(now: start.addingTimeInterval(100))
        let target = try FollowupFixture()
        try target.cache()
        try ListeningBackupStore(database: target.db).restore(backup)
        let restored = SessionStore(database: target.db)
        #expect(try restored.stats(sectionID: "A:2", now: start.addingTimeInterval(86400)).allTimeSeconds == 10)
        try restored.begin(bookRatingKey: "900", atMs: 10000, rate: 1, sectionID: "A:2", now: start.addingTimeInterval(86400))
        #expect(try restored.stats(sectionID: "A:2", now: start.addingTimeInterval(86400)).allTimeSeconds == 10)
    }

    @Test("Cloud-first records and unresolved rows are included without requiring cached metadata")
    func inboxAndUnresolved() throws {
        let source = try FollowupFixture()
        try source.progress.recordPosition(bookRatingKey: "uncached-legacy", absoluteMs: 321, at: start)
        try CloudSyncStore(database: source.db).apply([
            CloudRecord(kind: .progress, id: "plex:A:900", revision: 3,
                fields: ["absoluteMs": .int(123), "changedAt": .date(Date())]),
            CloudRecord(kind: .bookmark, id: "held-bookmark", revision: 2,
                fields: ["bookIdentity": .string("plex:A:900"), "createdAt": .date(start), "absoluteMs": .int(123)])
        ])
        let backup = try ListeningBackupStore(database: source.db).export()
        let target = try FollowupFixture()
        try ListeningBackupStore(database: target.db).restore(backup)
        try target.cache()
        #expect(try target.progress.progress(bookRatingKey: "900")?.absoluteMs == 123)
        #expect(try BookmarkStore(database: target.db).count(bookRatingKey: "900") == 1)
        let rows = try target.db.writer.read { try Row.fetchAll($0, sql: "SELECT book_rating_key, absolute_ms FROM progress") }
        #expect(rows.contains { ($0["absolute_ms"] as Int?) == 321 && ($0["book_rating_key"] as String? ?? "").hasPrefix("@identity:unresolved:") })
    }

    @Test("Malformed and unsupported backups leave all local data untouched")
    func validationIsAtomic() throws {
        let fixture = try FollowupFixture()
        try fixture.cache()
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 123, at: start)
        let store = ListeningBackupStore(database: fixture.db)
        let before = try store.export(now: start)
        var json = try #require(try JSONSerialization.jsonObject(with: before) as? [String: Any])
        json["version"] = 99
        #expect(throws: ListeningBackupError.self) { try store.restore(JSONSerialization.data(withJSONObject: json)) }
        json["version"] = 1
        var books = try #require(json["books"] as? [[String: Any]])
        books[0]["identity"] = "900" // A numeric row number is never portable.
        json["books"] = books
        #expect(throws: ListeningBackupError.self) { try store.restore(JSONSerialization.data(withJSONObject: json)) }
        #expect(throws: ListeningBackupError.self) { try store.restore(Data("not JSON".utf8)) }
        #expect(try store.export(now: start) == before)
    }

    @Test("Successful iCloud updates retain their timestamp when the store is recreated")
    func cloudHealthPersists() throws {
        let fixture = try FollowupFixture()
        try fixture.cache()
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 123)
        let cloud = CloudSyncStore(database: fixture.db)
        #expect(try cloud.pendingCount() == 1)
        try cloud.markPushed(cloud.pendingChanges())
        #expect(try cloud.pendingCount() == 0)
        #expect(try CloudSyncStore(database: fixture.db).lastSuccessfulSync() != nil)
    }
}
