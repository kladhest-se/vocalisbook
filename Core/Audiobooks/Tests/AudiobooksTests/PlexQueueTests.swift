import Foundation
import GRDB
import Testing
import PlexKit
@testable import Audiobooks

@Suite("Plex queue acknowledgements and retry timing")
struct PlexQueueTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A stale failure cannot delay or annotate a newer coalesced position")
    func staleFailure() throws {
        let store = SyncStore(database: try .inMemory())
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        let sent = try #require(try store.pendingOutbox(now: start).first)
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 200, at: start.addingTimeInterval(1))
        try store.markFailed(entry: sent, error: "old request failed", at: start.addingTimeInterval(2))
        let queued = try #require(try store.pendingOutbox(now: start.addingTimeInterval(2)).first)
        #expect(queued.id == sent.id)
        #expect(queued.absoluteMs == 200)
        #expect(queued.attempts == 0 && queued.lastError == nil && queued.lastAttemptAt == nil)
    }

    @Test("Returning to the same position does not acknowledge a newer revision")
    func samePositionNewRevision() throws {
        let store = SyncStore(database: try .inMemory())
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        let sent = try #require(try store.pendingOutbox(now: start).first)
        // Same timestamp as well: revision must distinguish these edits.
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        try store.markSynced(entry: sent, at: start.addingTimeInterval(2))
        let queued = try #require(try store.pendingOutbox(now: start.addingTimeInterval(2)).first)
        #expect(queued.revision == sent.revision + 1)
        #expect(try store.progress(bookRatingKey: "900")?.dirty == true)
        #expect(try store.progress(bookRatingKey: "900")?.syncedAt == nil)
    }

    @Test("An older position acknowledgement cannot clean a newer finished state")
    func newerFinishedState() throws {
        let store = SyncStore(database: try .inMemory())
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        let sent = try #require(try store.pendingOutbox(now: start).first)
        try store.markFinished(bookRatingKey: "900", at: start.addingTimeInterval(1))
        try store.markSynced(entry: sent, at: start.addingTimeInterval(2))
        let progress = try #require(try store.progress(bookRatingKey: "900"))
        #expect(progress.dirty && progress.finishedAt != nil)
        #expect(progress.syncedAt == nil)
        #expect(try store.pendingOutbox(now: start.addingTimeInterval(2)).map(\.kind) == [.finished])
    }

    @Test("An old acknowledgement cannot roll back a newer successful baseline")
    func acknowledgementOrder() throws {
        let store = SyncStore(database: try .inMemory())
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        let old = try #require(try store.pendingOutbox(now: start).first)
        try store.markFinished(bookRatingKey: "900", at: start.addingTimeInterval(1))
        let latest = try #require(try store.pendingOutbox(now: start).first { $0.kind == .finished })
        let syncedAt = start.addingTimeInterval(2)
        try store.markSynced(entry: latest, at: syncedAt)
        try store.markSynced(entry: old, at: start.addingTimeInterval(3))
        let progress = try #require(try store.progress(bookRatingKey: "900"))
        #expect(!progress.dirty && progress.syncedAt == syncedAt)
        #expect(progress.syncedOffsetMs == 100)
        #expect(try store.outboxDepth() == 0)
    }

    @Test("A removed completion command cannot acknowledge a reset")
    func oppositeCommandWasReplaced() throws {
        let store = SyncStore(database: try .inMemory())
        try store.markFinished(bookRatingKey: "900", at: start)
        let sent = try #require(try store.pendingOutbox(now: start).first)
        try store.resetProgress(bookRatingKey: "900", at: start.addingTimeInterval(1))
        try store.markSynced(entry: sent, at: start.addingTimeInterval(2))
        try store.markFailed(entry: sent, error: "late failure", at: start.addingTimeInterval(2))
        let queued = try #require(try store.pendingOutbox(now: start.addingTimeInterval(2)).first)
        #expect(queued.kind == .unfinished && queued.attempts == 0)
        #expect(try store.progress(bookRatingKey: "900")?.dirty == true)
    }

    @Test("An old offline event backs off from the failed request, not the event")
    func oldEventBackoff() throws {
        let store = SyncStore(database: try .inMemory())
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start.addingTimeInterval(-86400))
        let sent = try #require(try store.pendingOutbox(now: start).first)
        try store.markFailed(entry: sent, error: "offline", at: start)
        #expect(try store.pendingOutbox(now: start).isEmpty)
        #expect(try store.pendingOutbox(now: start.addingTimeInterval(1.9)).isEmpty)
        let retry = try #require(try store.pendingOutbox(now: start.addingTimeInterval(2)).first)
        #expect(retry.lastAttemptAt == start && retry.attempts == 1)
        #expect(retry.recordedAt == sent.recordedAt)
    }

    @Test("Repeated failures restart exponential backoff and cap it at one hour")
    func repeatedFailures() throws {
        let store = SyncStore(database: try .inMemory())
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        var now = start
        for attempt in 1...14 {
            let sent = try #require(try store.pendingOutbox(now: now).first)
            try store.markFailed(entry: sent, error: "offline", at: now)
            let delay = min(pow(2.0, Double(attempt)), 3600)
            #expect(try store.pendingOutbox(now: now.addingTimeInterval(delay - 0.01)).isEmpty)
            let retry = try #require(try store.pendingOutbox(now: now.addingTimeInterval(delay)).first)
            #expect(retry.attempts == attempt && retry.lastAttemptAt == now)
            now = now.addingTimeInterval(delay + 100)
        }
    }

    @Test("A new edit resets retry timing and errors for its replacement payload")
    func editResetsBackoff() throws {
        let store = SyncStore(database: try .inMemory())
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        let sent = try #require(try store.pendingOutbox(now: start).first)
        try store.markFailed(entry: sent, error: "offline", at: start)
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 200, at: start.addingTimeInterval(1))
        let new = try #require(try store.pendingOutbox(now: start.addingTimeInterval(1)).first)
        #expect(new.id == sent.id && new.absoluteMs == 200)
        #expect(new.attempts == 0 && new.lastAttemptAt == nil && new.lastError == nil)
    }

    @Test("Late duplicate responses do not recreate or alter an acknowledged row")
    func duplicateResponses() throws {
        let store = SyncStore(database: try .inMemory())
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        let sent = try #require(try store.pendingOutbox(now: start).first)
        try store.markSynced(entry: sent, at: start.addingTimeInterval(1))
        try store.markFailed(entry: sent, error: "late", at: start.addingTimeInterval(2))
        try store.markSynced(entry: sent, at: start.addingTimeInterval(3))
        #expect(try store.outboxDepth() == 0)
        #expect(try store.progress(bookRatingKey: "900")?.syncedAt == start.addingTimeInterval(1))
    }

    @Test("v16 retains pending mutations and starts a delay for legacy failed rows")
    func migrationPreservesQueue() throws {
        let queue = try DatabaseQueue()
        let migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v15_scoped_audio_and_complete_timelines")
        let failedID = UUID().uuidString, freshID = UUID().uuidString
        try queue.write { db in
            for (id, key, attempts) in [(failedID, "900", 3), (freshID, "901", 0)] {
                try db.execute(sql: """
                    INSERT INTO outbox (id, book_rating_key, kind, absolute_ms, recorded_at, revision, attempts, last_error)
                    VALUES (?, ?, 'position', 1234, ?, 7, ?, ?)
                    """, arguments: [id, key, start, attempts, attempts > 0 ? "offline" : nil])
            }
        }
        let before = Date().addingTimeInterval(-0.001)
        try migrator.migrate(queue)
        let after = Date().addingTimeInterval(0.001) // SQLite rounds dates to milliseconds.
        let rows = try queue.read { try OutboxRecord.order(Column("book_rating_key")).fetchAll($0) }
        #expect(rows.count == 2)
        let failed = try #require(rows.first?.entry), fresh = try #require(rows.last?.entry)
        #expect(failed.id.uuidString == failedID && fresh.id.uuidString == freshID)
        #expect(failed.recordedAt == start && fresh.recordedAt == start)
        #expect(failed.absoluteMs == 1234 && failed.revision == 7 && failed.attempts == 3)
        #expect(failed.lastError == "offline")
        let attemptAt = try #require(failed.lastAttemptAt)
        #expect(attemptAt >= before && attemptAt <= after)
        #expect(fresh.lastAttemptAt == nil && fresh.attempts == 0)
    }

    @Test("A drain preserves playback recorded during its request and sends it next")
    func drainDuringPlayback() async throws {
        let db = try AudiobookDatabase.inMemory()
        try await db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO server (machine_identifier, name, last_connection_was_relay) VALUES ('srv', 'Test', 0)")
            try conn.execute(sql: "INSERT INTO library_section (id, server_id, section_key, title) VALUES ('srv:2', 'srv', '2', 'Books')")
        }
        let library = LibraryStore(database: db), store = SyncStore(database: db)
        let book = try JSONDecoder().decode(PlexBook.self, from: Data("{\"ratingKey\":\"900\",\"title\":\"Book\"}".utf8))
        let track = try JSONDecoder().decode(PlexTrack.self, from: Data("""
            {"ratingKey":"t1","key":"/library/metadata/t1","title":"Part","index":1,"duration":10000,
             "Media":[{"Part":[{"id":"1","key":"/part.mp3","size":100}]}]}
            """.utf8))
        try library.cache(book: book, tracks: [track], chapters: [], sectionID: "srv:2")
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: start)
        let server = PlaybackDuringRequest(store: store, changedAt: start.addingTimeInterval(1))
        let connection = ResolvedConnection(serverIdentifier: "srv", baseURL: URL(string: "https://plex.example:32400")!,
            accessToken: "fixture", isLocal: true, isRelay: false, resolvedAt: start, probeLatency: .milliseconds(1))
        let identity = PlexClientIdentity(clientIdentifier: "TEST", product: "VocalisBook", version: "1",
            device: "Test", deviceName: "Test", platform: "test", platformVersion: "1")
        let client = PlexServerClient(connection: connection, transport: PlexTransport(client: server, identity: identity))
        let sync = ProgressSync(client: client, store: store, library: library)
        let first = try await sync.drain()
        #expect(first.pushed == 1 && first.remaining == 1)
        #expect(try store.progress(bookRatingKey: "900")?.dirty == true)
        #expect(try store.pendingOutbox().first?.absoluteMs == 200)
        let second = try await sync.drain()
        #expect(second.pushed == 1 && second.remaining == 0)
        #expect(try store.progress(bookRatingKey: "900")?.dirty == false)
        #expect(try store.progress(bookRatingKey: "900")?.syncedOffsetMs == 200)
        #expect(await server.offsets == ["100", "200"])
    }
}

/// Advances local playback before the first request returns, reproducing the
/// in-flight coalescing race without timing-sensitive sleeps or a live server.
private actor PlaybackDuringRequest: HTTPClient {
    let store: SyncStore
    let changedAt: Date
    var offsets: [String] = []

    init(store: SyncStore, changedAt: Date) {
        self.store = store
        self.changedAt = changedAt
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        offsets.append(query?.first { $0.name == "time" }?.value ?? "missing")
        if offsets.count == 1 {
            try store.recordPosition(bookRatingKey: "900", absoluteMs: 200, at: changedAt)
        }
        return HTTPResponse(status: 200, body: Data())
    }
}
