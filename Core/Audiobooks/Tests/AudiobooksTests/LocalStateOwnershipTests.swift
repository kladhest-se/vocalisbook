import Foundation
import GRDB
import Testing
import PlexKit
@testable import Audiobooks

@Suite("Retained local identities and session ownership")
struct LocalStateOwnershipTests {
    private func cache(_ db: AudiobookDatabase, server: String, key: String, guid: String? = nil) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT OR IGNORE INTO server (machine_identifier, name, last_connection_was_relay) VALUES (?, ?, 0)", arguments: [server, server])
            try conn.execute(sql: "INSERT OR IGNORE INTO library_section (id, server_id, section_key, title) VALUES (?, ?, '2', 'Books')", arguments: ["\(server):2", server])
        }
        var obj = ["ratingKey": key, "title": "Book"]
        if let guid { obj["guid"] = guid }
        let book = try JSONDecoder().decode(PlexBook.self, from: JSONSerialization.data(withJSONObject: obj))
        try LibraryStore(database: db).cacheBookList([book], sectionID: "\(server):2")
    }

    @Test("A different server cannot inherit progress, speed, bookmarks or pending Plex writes")
    func collidingServerKeys() throws {
        let db = try AudiobookDatabase.inMemory()
        let sync = SyncStore(database: db), bookmarks = BookmarkStore(database: db)
        try cache(db, server: "A", key: "900")
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 42_000)
        try sync.setRate(1.5, bookRatingKey: "900")
        try bookmarks.add(bookRatingKey: "900", absoluteMs: 42_000)
        try db.purgeMetadataCache()
        try cache(db, server: "B", key: "900")
        #expect(try sync.progress(bookRatingKey: "900") == nil)
        #expect(try sync.rate(bookRatingKey: "900") == nil)
        #expect(try bookmarks.bookmarks(bookRatingKey: "900").isEmpty)
        #expect(try sync.pendingOutbox().allSatisfy { $0.bookRatingKey != "900" })
        try db.purgeMetadataCache()
        try cache(db, server: "A", key: "900")
        #expect(try sync.progress(bookRatingKey: "900")?.absoluteMs == 42_000)
        #expect(try sync.rate(bookRatingKey: "900") == 1.5)
        #expect(try bookmarks.bookmarks(bookRatingKey: "900").count == 1)
    }

    @Test("The same portable book reattaches under a new server key without iCloud")
    func portableIdentity() throws {
        let db = try AudiobookDatabase.inMemory()
        let guid = "com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en"
        try cache(db, server: "A", key: "900", guid: guid)
        try SyncStore(database: db).recordPosition(bookRatingKey: "900", absoluteMs: 123)
        let sessions = SessionStore(database: db)
        try sessions.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "A:2")
        try sessions.end(atMs: 123)
        try db.purgeMetadataCache()
        try cache(db, server: "B", key: "901", guid: guid)
        #expect(try SyncStore(database: db).progress(bookRatingKey: "901")?.absoluteMs == 123)
        let rows = try db.writer.read { conn in try Row.fetchAll(conn, sql: "SELECT book_rating_key, library_section_id FROM listening_session") }
        #expect(rows.first?["book_rating_key"] as String? == "901")
        #expect(rows.first?["library_section_id"] as String? == "B:2")
    }

    @Test("Replacing cached metadata with a different identity detaches the previous book")
    func reusedCachedKey() throws {
        let db = try AudiobookDatabase.inMemory()
        try cache(db, server: "A", key: "900", guid: "com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en")
        try SyncStore(database: db).recordPosition(bookRatingKey: "900", absoluteMs: 123)
        try cache(db, server: "B", key: "900")
        #expect(try SyncStore(database: db).progress(bookRatingKey: "900") == nil)
    }

    @Test("Stopping or starting this device never closes an imported remote session")
    func remoteOpenSession() throws {
        let db = try AudiobookDatabase.inMemory()
        try cache(db, server: "A", key: "900")
        let local = SessionStore(database: db)
        try local.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "A:2")
        try CloudSyncStore(database: db).apply([
            CloudRecord(kind: .listeningSession, id: "remote", revision: 1, fields: [
                "bookIdentity": .string("plex:A:900"), "originDeviceID": .string("other-device"),
                "startedAt": .date(Date()), "startMs": .int(5)
            ])
        ])
        try local.end(atMs: 100)
        try local.begin(bookRatingKey: "900", atMs: 100, rate: 1, sectionID: "A:2")
        let remote = try db.writer.read { conn in try Row.fetchOne(conn, sql: "SELECT * FROM listening_session WHERE id = 'remote'") }
        #expect(remote?["ended_at"] as Date? == nil)
        #expect(remote?["end_ms"] as Int? == nil)
        #expect(remote?["revision"] as Int? == 1)
        #expect(remote?["dirty"] as Bool? == false)
    }

    @Test("A newly created session store cannot close a previous process's active session")
    func staleLocalSessionAfterRestart() throws {
        let db = try AudiobookDatabase.inMemory()
        let oldStore = SessionStore(database: db)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try oldStore.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "A:2", now: start)
        let relaunched = SessionStore(database: db)
        try relaunched.end(atMs: 50, now: start.addingTimeInterval(86400))
        let end = try db.writer.read { conn in try Date.fetchOne(conn, sql: "SELECT ended_at FROM listening_session WHERE id = ?", arguments: [id]) }
        #expect(end == nil)
    }

    @Test("Legacy orphan data is retained but cannot bind to newly cached row numbers")
    func migrationQuarantinesOrphans() throws {
        let queue = try DatabaseQueue()
        let migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v13_cloud_record_inbox")
        try queue.write { conn in
            try conn.execute(sql: "INSERT INTO progress (book_rating_key, absolute_ms, changed_at) VALUES ('900', 42, ?)", arguments: [Date()])
        }
        try migrator.migrate(queue)
        let key = try queue.read { conn in try String.fetchOne(conn, sql: "SELECT book_rating_key FROM progress") }
        #expect(key == "@unresolved:900")
    }
}
