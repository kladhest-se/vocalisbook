import Foundation
import GRDB
import Testing
import PlexKit
@testable import Audiobooks

@Suite("Cloud identity isolation and deferred records")
struct CloudInboxTests {
    private let guid = "com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en"

    private func makeDatabase() throws -> AudiobookDatabase {
        let db = try AudiobookDatabase.inMemory()
        try db.writer.write { connection in
            for server in ["A", "B"] {
                try connection.execute(sql: """
                    INSERT INTO server (machine_identifier, name, last_connection_was_relay)
                    VALUES (?, ?, 0)
                    """, arguments: [server, server])
                try connection.execute(sql: """
                    INSERT INTO library_section (id, server_id, section_key, title)
                    VALUES (?, ?, '2', 'Books')
                    """, arguments: ["\(server):2", server])
            }
        }
        return db
    }

    private func cacheBook(_ db: AudiobookDatabase, key: String, guid: String? = nil) throws {
        var object = ["ratingKey": key, "title": "Book"]
        if let guid { object["guid"] = guid }
        let book = try JSONDecoder().decode(PlexBook.self, from: JSONSerialization.data(withJSONObject: object))
        try LibraryStore(database: db).cacheBookList([book], sectionID: "B:2")
    }

    @Test("A server fallback never resolves another server's identical rating key")
    func serverCollision() throws {
        let db = try makeDatabase()
        try cacheBook(db, key: "900", guid: guid)
        try db.writer.read { (connection: Database) throws -> Void in
            #expect(try CloudSyncStore.localBook(for: "plex:A:900", db: connection) == nil)
            #expect(try CloudSyncStore.localBook(for: "plex:B:900", db: connection) == "900")
        }
        try CloudSyncStore(database: db).apply([
            CloudRecord(kind: .progress, id: "plex:A:900", revision: 1,
                        fields: ["absoluteMs": .int(500), "changedAt": .date(Date())])
        ])
        try db.writer.read { (connection: Database) throws -> Void in
            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM progress") == 0)
        }
    }

    @Test("Cloud-first bookmarks, sessions and speed attach when the right book arrives")
    func cloudBeforeLibrary() throws {
        let db = try makeDatabase()
        try cacheBook(db, key: "900") // An unrelated book with the sender's key.
        let store = CloudSyncStore(database: db)
        // Derive the wire identity using the same public contract as the app.
        let portable = BookIdentity.from(guid: guid, serverIdentifier: "A", ratingKey: "900").key
        let records = [
            CloudRecord(kind: .bookmark, id: "bookmark", revision: 3, fields: [
                "bookIdentity": .string(portable), "bookRatingKey": .string("900"),
                "absoluteMs": .int(500), "label": .string("Keep me"), "createdAt": .date(Date())
            ]),
            CloudRecord(kind: .listeningSession, id: "session", revision: 2, fields: [
                "bookIdentity": .string(portable), "bookRatingKey": .string("900"),
                "startedAt": .date(Date()), "startMs": .int(0), "endMs": .int(500)
            ]),
            CloudRecord(kind: .bookSettings, id: portable, revision: 2, fields: ["rate": .double(1.5)])
        ]
        try store.apply(records)
        #expect(try BookmarkStore(database: db).bookmarks(bookRatingKey: "900").isEmpty)
        // An older incoming update must not overwrite the held label.
        try store.apply([CloudRecord(kind: .bookmark, id: "bookmark", revision: 1,
                                     fields: ["bookIdentity": .string(portable), "label": .string("Old")])])
        try cacheBook(db, key: "901", guid: guid)
        let bookmark = try #require(BookmarkStore(database: db).bookmarks(bookRatingKey: "901").first)
        #expect(bookmark.label == "Keep me")
        try db.writer.read { (connection: Database) throws -> Void in
            #expect(try String.fetchOne(connection, sql: "SELECT book_rating_key FROM listening_session WHERE id = 'session'") == "901")
            #expect(try String.fetchOne(connection, sql: "SELECT library_section_id FROM listening_session WHERE id = 'session'") == "B:2")
            #expect(try Double.fetchOne(connection, sql: "SELECT rate FROM book_settings WHERE book_rating_key = '901'") == 1.5)
            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM cloud_pending_record") == 0)
        }
        #expect(try store.pendingChanges().isEmpty)
    }

    @Test("An unresolved deletion supersedes a held bookmark instead of resurrecting it")
    func heldDeletion() throws {
        let db = try makeDatabase()
        let portable = BookIdentity.from(guid: guid, serverIdentifier: "A", ratingKey: "900").key
        let store = CloudSyncStore(database: db)
        try store.apply([
            CloudRecord(kind: .bookmark, id: "bookmark", revision: 1,
                        fields: ["bookIdentity": .string(portable), "absoluteMs": .int(5)]),
            CloudRecord(kind: .bookmark, id: "bookmark", revision: 2, isDeleted: true,
                        fields: ["bookIdentity": .string(portable)])
        ])
        try cacheBook(db, key: "901", guid: guid)
        #expect(try BookmarkStore(database: db).bookmarks(bookRatingKey: "901").isEmpty)
    }

    @Test("Clearing listening data also clears all deferred cloud records")
    func purgeInbox() throws {
        let db = try makeDatabase()
        try CloudSyncStore(database: db).apply([
            CloudRecord(kind: .bookmark, id: "bookmark", revision: 1,
                        fields: ["bookIdentity": .string("plex:A:900")]),
            CloudRecord(kind: .progress, id: "plex:A:900", revision: 1,
                        fields: ["absoluteMs": .int(5), "changedAt": .date(Date())])
        ])
        try db.purgeSyncedUserData()
        try db.writer.read { (connection: Database) throws -> Void in
            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM cloud_pending_record") == 0)
            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM cloud_progress") == 0)
        }
    }
}
