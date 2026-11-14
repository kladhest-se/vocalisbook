import Foundation
import GRDB
import Testing
import PlexKit
@testable import Audiobooks

@Suite("Complete timelines and safe legacy audio")
struct AudioReliabilityTests {
    private func track(_ id: Int, duration: Int? = 1000, part: Bool = true, key: String = "/part.mp3") throws -> PlexTrack {
        var object: [String: Any] = ["ratingKey": "t\(id)", "key": "/metadata/t\(id)", "title": "Part \(id)", "index": id]
        if let duration { object["duration"] = duration }
        if part { object["Media"] = [["Part": [["id": "\(id)", "key": key, "size": 100]]]] }
        return try JSONDecoder().decode(PlexTrack.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func book() throws -> PlexBook {
        try JSONDecoder().decode(PlexBook.self, from: Data("{\"ratingKey\":\"900\",\"title\":\"Book\"}".utf8))
    }
    private func seed(_ db: AudiobookDatabase, server: String) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT OR IGNORE INTO server (machine_identifier, name, last_connection_was_relay) VALUES (?, ?, 0)", arguments: [server, server])
            try conn.execute(sql: "INSERT OR IGNORE INTO library_section (id, server_id, section_key, title) VALUES (?, ?, '2', 'Books')", arguments: ["\(server):2", server])
        }
    }

    @Test("A missing middle track's metadata cannot shorten the book", arguments: ["duration", "part", "key", "count"])
    func missingMiddleMetadata(reason: String) throws {
        let tracks = try [track(1), track(2, duration: reason == "duration" ? nil : 1000,
                                        part: reason != "part", key: reason == "key" ? "" : "/part.mp3"), track(3)]
        let timeline = BookTimeline(bookRatingKey: "900", tracks: tracks,
                                    expectedTrackCount: reason == "count" ? 4 : 3)
        #expect(!timeline.isComplete)
        #expect(timeline.segments.isEmpty)
        #expect(timeline.totalDurationMs == 0)
        #expect(timeline.locate(absoluteMs: 1500) == nil)
    }

    @Test("An incomplete refresh leaves an existing valid timeline and position intact")
    func incompleteCacheWriteIsRejected() throws {
        let db = try AudiobookDatabase.inMemory()
        try seed(db, server: "A")
        let library = LibraryStore(database: db), sync = SyncStore(database: db)
        try library.cache(book: book(), tracks: [track(1), track(2), track(3)], chapters: [], sectionID: "A:2")
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 1500)
        #expect(throws: SyncError.metadataIncomplete(ratingKey: "900")) {
            try library.cache(book: book(), tracks: [track(1), track(2, duration: nil), track(3)], chapters: [], sectionID: "A:2")
        }
        #expect(try library.timeline(bookRatingKey: "900")?.totalDurationMs == 3000)
        #expect(try sync.progress(bookRatingKey: "900")?.absoluteMs == 1500)
    }

    @Test("A second server with identical book/part numbers cannot use the first server's audio")
    func audioIsolation() throws {
        let db = try AudiobookDatabase.inMemory()
        let library = LibraryStore(database: db), downloads = DownloadStore(database: db)
        try seed(db, server: "A")
        try library.cache(book: book(), tracks: [track(1)], chapters: [], sectionID: "A:2")
        let first = try #require(try library.timeline(bookRatingKey: "900")).segments
        try downloads.enqueue(bookRatingKey: "900", segments: first)
        try downloads.markComplete(partCacheKey: first[0].partCacheKey, relativePath: "server-a.mp3", bytes: 100)
        try db.purgeMetadataCache()
        try seed(db, server: "B")
        try library.cache(book: book(), tracks: [track(1)], chapters: [], sectionID: "B:2")
        let second = try #require(try library.timeline(bookRatingKey: "900")).segments
        #expect(first[0].partCacheKey != second[0].partCacheKey)
        #expect(try downloads.relativePath(forPartCacheKey: second[0].partCacheKey) == nil)
        #expect(try downloads.state(bookRatingKey: "900", partCacheKeys: second.map(\.partCacheKey)) == .notDownloaded)
    }

    @Test("v15 retains legacy files and metadata but never trusts unscoped audio for playback")
    func legacyMigrationRetainsData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let queue = try DatabaseQueue(path: url.path), migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v14_local_identity_and_session_owner")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO server (machine_identifier, name, last_connection_was_relay) VALUES ('A','A',0)")
            try db.execute(sql: "INSERT INTO library_section (id,server_id,section_key,title) VALUES ('A:2','A','2','Books')")
            try db.execute(sql: "INSERT INTO book (rating_key,library_section_id,title,cached_at) VALUES ('900','A:2','Book',?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO track (rating_key,book_rating_key,idx,title,duration_ms,start_ms,plex_key,part_id,part_key,part_cache_key) VALUES ('t1','900',0,'Part',1000,0,'/t1','1','/part.mp3','1-s100')")
            try db.execute(sql: "INSERT INTO chapter (book_rating_key,idx,title,start_ms,end_ms,source) VALUES ('900',0,'Chapter',0,1000,'trackBoundary')")
            try db.execute(sql: "INSERT INTO download (part_cache_key,book_rating_key,track_rating_key,state,bytes_done,bytes_total,relative_path,completed_at) VALUES ('1-s100','900','t1','complete',100,100,'legacy.mp3',?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO progress (book_rating_key,absolute_ms,changed_at) VALUES ('900',500,?)", arguments: [Date()])
        }
        try migrator.migrate(queue)
        let db = try AudiobookDatabase.open(at: url, durability: .durable)
        let downloads = DownloadStore(database: db)
        let old = try #require(try downloads.record(partCacheKey: "1-s100"))
        #expect(old.requiresVerification)
        #expect(old.relativePath == "legacy.mp3" && old.bytesDone == 100)
        #expect(try downloads.relativePath(forPartCacheKey: "1-s100") == nil)
        #expect(try downloads.totalBytes() == 100)
        #expect(try downloads.discardStale(bookRatingKey: "900", keeping: ["s-new-key"]) == 0)
        #expect(try downloads.allRelativePaths().contains("legacy.mp3"))
        try downloads.markComplete(partCacheKey: "1-s100", relativePath: "wrong.mp3", bytes: 100)
        #expect(try downloads.record(partCacheKey: "1-s100")?.state == "failed")
        #expect(try LibraryStore(database: db).timeline(bookRatingKey: "900") == nil)
        let retained = try db.writer.read { conn in
            (try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM track"), try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM chapter"))
        }
        #expect(retained.0 == 1 && retained.1 == 1)
        #expect(try SyncStore(database: db).progress(bookRatingKey: "900")?.absoluteMs == 500)
        try db.purgeMetadataCache()
        #expect(try downloads.evictMissingFromLibrary().isEmpty)
        #expect(try downloads.allRelativePaths().contains("legacy.mp3"))
        #expect(try downloads.evictAll() == ["legacy.mp3"])
        #expect(try downloads.allRelativePaths().isEmpty)
    }
}
