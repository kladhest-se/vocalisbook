import Foundation
import GRDB
import Testing
@testable import Audiobooks

@Suite("Checkpoint and metadata upgrades")
struct FollowupMigrationTests {
    @Test("v17 through v19 retain legacy sessions and metadata without guessing checkpoint time")
    func retainedRows() throws {
        let queue = try DatabaseQueue(), migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v16_plex_outbox_attempt_time")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO server (machine_identifier,name,last_connection_was_relay) VALUES ('A','A',0)")
            try db.execute(sql: "INSERT INTO library_section (id,server_id,section_key,title) VALUES ('A:2','A','2','Books')")
            try db.execute(sql: "INSERT INTO book (rating_key,library_section_id,title,cached_at,timeline_complete) VALUES ('900','A:2','Book',?,1)", arguments: [date])
            try db.execute(sql: "INSERT INTO book_series (book_rating_key,name) VALUES ('900','Series')")
            try db.execute(sql: "INSERT INTO progress (book_rating_key,absolute_ms,changed_at) VALUES ('900',123,?)", arguments: [date])
            try db.execute(sql: "INSERT INTO listening_session (id,book_rating_key,started_at,start_ms,rate,revision,dirty,origin_device_id) VALUES ('legacy','900',?,0,1,7,1,(SELECT identifier FROM local_device WHERE singleton=1))", arguments: [date])
        }
        try migrator.migrate(queue)
        try queue.read { db in
            let session = try #require(try Row.fetchOne(db, sql: "SELECT * FROM listening_session"))
            #expect(session["started_at"] as Date? == date && session["revision"] as Int? == 7)
            #expect(session["ended_at"] as Date? == nil && session["last_listened_at"] as Date? == nil)
            let book = try #require(try BookRecord.fetchOne(db, key: "900"))
            #expect(book.title == "Book" && book.detailNeedsRefresh && book.recordingReleaseDate == nil)
            #expect(book.v4Payload == nil && !book.v4Available && book.metadataRevision == nil && book.artworkRevision == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recording_metadata_archive") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM identity_upgrade_backups") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT absolute_ms FROM progress") == 123)
            #expect(try String.fetchOne(db, sql: "SELECT name FROM book_series") == "Series")
            #expect(try Int.fetchOne(db, sql: "SELECT display_order FROM book_series") == 0)
        }
    }
}
