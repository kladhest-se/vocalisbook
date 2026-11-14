import Foundation
import GRDB
import Testing
import PlexKit
@testable import Audiobooks

struct FollowupFixture {
    let db: AudiobookDatabase
    let library: LibraryStore
    let progress: SyncStore
    init() throws {
        db = try .inMemory()
        library = LibraryStore(database: db)
        progress = SyncStore(database: db)
        try db.writer.write { conn in
            for server in ["A", "B"] {
                try conn.execute(sql: "INSERT INTO server (machine_identifier,name,last_connection_was_relay) VALUES (?,?,0)", arguments: [server, server])
                try conn.execute(sql: "INSERT INTO library_section (id,server_id,section_key,title) VALUES (?,?,'2','Books')", arguments: [server + ":2", server])
            }
        }
    }
    func book(_ key: String = "900", fields: [String: Any] = [:]) throws -> PlexBook {
        var json: [String: Any] = ["ratingKey": key, "title": "Book " + key]
        json.merge(fields) { _, new in new }
        return try JSONDecoder().decode(PlexBook.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func cache(_ key: String = "900", server: String = "A", fields: [String: Any] = [:]) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT OR IGNORE INTO library_section (id,server_id,section_key,title) VALUES (?,?,'2','Books')", arguments: [server + ":2", server])
        }
        let track = try JSONDecoder().decode(PlexTrack.self, from: JSONSerialization.data(withJSONObject: [
            "ratingKey": "t" + key, "key": "/library/metadata/t" + key, "title": "Part", "duration": 600000,
            "Media": [["Part": [["id": key, "key": "/part/" + key + ".mp3", "size": 100]]]]
        ]))
        try library.cache(book: book(key, fields: fields), tracks: [track], chapters: [], sectionID: server + ":2")
    }
    func client(_ http: any HTTPClient, server: String = "A") -> PlexServerClient {
        let identity = PlexClientIdentity(clientIdentifier: "fixture", product: "VocalisBook", version: "1",
            device: "Test", deviceName: "Test", platform: "test", platformVersion: "1")
        let connection = ResolvedConnection(serverIdentifier: server, baseURL: URL(string: "https://fixture.example")!,
            accessToken: "fixture-only", isLocal: true, isRelay: false, resolvedAt: Date(), probeLatency: .milliseconds(1))
        return PlexServerClient(connection: connection, transport: PlexTransport(client: http, identity: identity))
    }
}

@Suite("Remaining reliability fixes")
struct FollowupReliabilityTests {
    @Test("Independent sync values cannot overtake an older upload")
    func serializedUploads() async throws {
        let fixture = try FollowupFixture()
        try fixture.cache()
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 100)
        let server = SuspendedTimelineServer()
        let firstSync = ProgressSync(client: fixture.client(server), store: fixture.progress, library: fixture.library)
        let secondSync = ProgressSync(client: fixture.client(server), store: SyncStore(database: fixture.db), library: fixture.library)
        let first = Task { try await firstSync.drain() }
        await server.waitForFirst()
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 200)
        let second = Task { try await secondSync.drain() }
        // Give the second task a chance to enter the shared upload queue. The
        // first request cannot finish until this test explicitly releases it.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await server.received == ["100"])
        await server.releaseFirst()
        _ = try await first.value
        _ = try await second.value
        #expect(await server.applied == ["100", "200"])
        #expect(try fixture.progress.outboxDepth() == 0)
        #expect(try fixture.progress.progress(bookRatingKey: "900")?.syncedOffsetMs == 200)
    }

    @Test("An old server's queued sync cannot send the active server's reused row number")
    func uploadServerScope() async throws {
        let fixture = try FollowupFixture()
        try fixture.cache(server: "B")
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 100)
        let server = CountingTimelineServer()
        let old = ProgressSync(client: fixture.client(server, server: "A"), store: fixture.progress, library: fixture.library)
        let result = try await old.drain()
        #expect(result.pushed == 0 && result.remaining == 1 && result.failed == 0)
        #expect(await server.requests == 0)
        #expect(try fixture.progress.progress(bookRatingKey: "900")?.dirty == true)
    }

    @Test("Full scans remove absent metadata while retaining identity-owned history and downloaded copies")
    func fullScanRetention() throws {
        let fixture = try FollowupFixture()
        for key in ["900", "901", "902"] { try fixture.cache(key) }
        try fixture.cache("903", server: "B")
        try fixture.progress.recordPosition(bookRatingKey: "902", absoluteMs: 123)
        let bookmarks = BookmarkStore(database: fixture.db)
        try bookmarks.add(bookRatingKey: "902", absoluteMs: 123)
        let downloads = DownloadStore(database: fixture.db)
        let timeline = try #require(try fixture.library.timeline(bookRatingKey: "901"))
        try downloads.enqueue(bookRatingKey: "901", segments: timeline.segments)
        try downloads.markComplete(partCacheKey: timeline.segments[0].partCacheKey, relativePath: "keep.mp3", bytes: 100)
        let removed = try fixture.library.reconcileFullScan(sectionID: "A:2", seen: ["900"], startedAt: Date().addingTimeInterval(1))
        #expect(removed == 1)
        #expect(try fixture.library.book(ratingKey: "902") == nil)
        #expect(try fixture.library.book(ratingKey: "901") != nil)
        #expect(try fixture.library.book(ratingKey: "903") != nil)
        #expect(try downloads.allRelativePaths() == ["keep.mp3"])
        #expect(try fixture.progress.progress(bookRatingKey: "@identity:plex:A:902")?.absoluteMs == 123)
        try fixture.cache("902")
        #expect(try fixture.progress.progress(bookRatingKey: "902")?.absoluteMs == 123)
        #expect(try bookmarks.count(bookRatingKey: "902") == 1)
    }

    @Test("Incomplete pagination cannot remove cached books or advance the sync stamp")
    func incompleteScanPreservesBooks() async throws {
        let fixture = try FollowupFixture()
        try fixture.cache("902")
        let sync = LibrarySync(client: fixture.client(IncompleteLibraryServer()), store: fixture.library,
            progress: fixture.progress, downloadStore: DownloadStore(database: fixture.db), sectionID: "A:2", sectionKey: "2")
        await #expect(throws: SyncError.incompleteLibrary) { try await sync.refreshBooks(pageSize: 2) }
        #expect(try fixture.library.book(ratingKey: "902") != nil)
        #expect(try fixture.library.lastSynced(sectionID: "A:2") == nil)
    }

    @Test("A relaunched store recovers confirmed playback without counting downtime")
    func checkpointRecovery() throws {
        let fixture = try FollowupFixture()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = SessionStore(database: fixture.db)
        let id = try first.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "A:2", now: start)
        try first.checkpoint(atMs: 10000, now: start.addingTimeInterval(10))
        // Out-of-order checkpoint callbacks cannot move confirmed time back.
        try first.checkpoint(atMs: 5000, now: start.addingTimeInterval(5))
        let relaunched = SessionStore(database: fixture.db)
        try relaunched.begin(bookRatingKey: "900", atMs: 10000, rate: 1, sectionID: "A:2", now: start.addingTimeInterval(86400))
        let row = try fixture.db.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM listening_session WHERE id = ?", arguments: [id]) }
        #expect(row?["ended_at"] as Date? == start.addingTimeInterval(10))
        #expect(row?["end_ms"] as Int? == 10000)
        #expect(try relaunched.stats(sectionID: "A:2", now: start.addingTimeInterval(86400)).allTimeSeconds == 10)
    }

    @Test("Overlapping device sessions count once without modifying individual recordings")
    func overlappingStatistics() throws {
        let fixture = try FollowupFixture(), store = SessionStore(database: fixture.db)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, length) in [(0, 1800), (900, 1800), (1000, 100), (2700, 300)] {
            try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "A:2", now: start.addingTimeInterval(Double(offset)))
            try store.end(atMs: 0, now: start.addingTimeInterval(Double(offset + length)))
        }
        let stats = try store.stats(sectionID: "A:2", now: start.addingTimeInterval(3600))
        #expect(stats.allTimeSeconds == 3000)
        let count = try fixture.db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM listening_session") }
        #expect(count == 4)
    }

    @Test("Queue status persists successes, reports failures and offers a payload-preserving retry")
    func queueHealth() throws {
        let fixture = try FollowupFixture()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 100, at: now)
        let sent = try #require(try fixture.progress.pendingOutbox(now: now).first)
        try fixture.progress.markSynced(entry: sent, at: now)
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 200, at: now.addingTimeInterval(1))
        let failed = try #require(try fixture.progress.pendingOutbox(now: now.addingTimeInterval(1)).first)
        try fixture.progress.markFailed(entry: failed, error: "offline", at: now.addingTimeInterval(1))
        let status = try SyncStore(database: fixture.db).queueStatus(now: now.addingTimeInterval(1))
        #expect(status.pending == 1 && status.failed == 1 && status.lastSuccess == now)
        #expect(status.nextRetry == now.addingTimeInterval(3) && status.lastError == "offline")
        try fixture.progress.retryFailedOutbox()
        let retry = try #require(try fixture.progress.pendingOutbox(now: now.addingTimeInterval(1)).first)
        #expect(retry.id == failed.id && retry.absoluteMs == failed.absoluteMs && retry.revision == failed.revision)
        #expect(retry.attempts == 0 && retry.lastError == nil)
    }
    @Test("Cancelled waiting uploads leave new work queued and release the serial queue")
    func cancelledQueuedUpload() async throws {
        let fixture = try FollowupFixture()
        try fixture.cache()
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 100)
        let server = SuspendedTimelineServer()
        let sync = ProgressSync(client: fixture.client(server), store: fixture.progress, library: fixture.library)
        let first = Task { try await sync.drain() }
        await server.waitForFirst()
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 200)
        let second = Task { try await sync.drain() }
        try await Task.sleep(for: .milliseconds(30))
        second.cancel()
        await server.releaseFirst()
        _ = try await first.value
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(try fixture.progress.pendingOutbox().first?.absoluteMs == 200)
        #expect(try fixture.progress.pendingOutbox().first?.attempts == 0)
        _ = try await sync.drain()
        #expect(await server.applied == ["100", "200"])
    }

    @Test("Incremental scans retain unseen books; a completed full scan reconciles them")
    func fullVersusIncrementalScan() async throws {
        let fixture = try FollowupFixture()
        try fixture.cache("900")
        try fixture.cache("902")
        try fixture.library.markSynced(sectionID: "A:2", at: Date().addingTimeInterval(-60))
        let sync = LibrarySync(client: fixture.client(CompleteLibraryServer()), store: fixture.library,
            progress: fixture.progress, downloadStore: DownloadStore(database: fixture.db), sectionID: "A:2", sectionKey: "2")
        _ = try await sync.refreshBooks(incremental: true)
        #expect(try fixture.library.book(ratingKey: "902") != nil)
        _ = try await sync.refreshBooks(incremental: false)
        #expect(try fixture.library.book(ratingKey: "902") == nil)
        #expect(try fixture.library.book(ratingKey: "900") != nil)
    }

    @Test("Startup recovery makes confirmed listening visible before playback restarts")
    func startupRecovery() throws {
        let fixture = try FollowupFixture()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let old = SessionStore(database: fixture.db)
        try old.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "A:2", now: start)
        try old.checkpoint(atMs: 10000, now: start.addingTimeInterval(10))
        let new = SessionStore(database: fixture.db)
        try new.recoverInterruptedSessions()
        #expect(try new.stats(sectionID: "A:2", now: start.addingTimeInterval(86400)).allTimeSeconds == 10)
    }
    @Test("Changing page totals cannot reconcile a moving library as a complete snapshot")
    func changingLibraryDuringScan() async throws {
        let fixture = try FollowupFixture()
        try fixture.cache("902")
        let sync = LibrarySync(client: fixture.client(ChangingLibraryServer()), store: fixture.library,
            progress: fixture.progress, downloadStore: DownloadStore(database: fixture.db), sectionID: "A:2", sectionKey: "2")
        await #expect(throws: SyncError.incompleteLibrary) { try await sync.refreshBooks(pageSize: 1) }
        #expect(try fixture.library.book(ratingKey: "902") != nil)
        #expect(try fixture.library.lastSynced(sectionID: "A:2") == nil)
    }
}

private actor SuspendedTimelineServer: HTTPClient {
    var received: [String] = []
    var applied: [String] = []
    private var first: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func waitForFirst() async {
        if !received.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseFirst() { first?.resume(); first = nil }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let offset = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "time" }?.value ?? "missing"
        received.append(offset)
        if received.count == 1 {
            await withCheckedContinuation { first = $0; started?.resume(); started = nil }
        }
        applied.append(offset)
        return HTTPResponse(status: 200, body: Data())
    }
}
private actor CountingTimelineServer: HTTPClient {
    var requests = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        return HTTPResponse(status: 200, body: Data())
    }
}
private actor IncompleteLibraryServer: HTTPClient {
    var page = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        defer { page += 1 }
        let json = page == 0
            ? #"{"MediaContainer":{"size":1,"totalSize":2,"Metadata":[{"ratingKey":"900","title":"Book"}]}}"#
            : #"{"MediaContainer":{"size":0,"totalSize":2,"Metadata":[]}}"#
        return HTTPResponse(status: 200, body: Data(json.utf8))
    }
}

private struct CompleteLibraryServer: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let json = request.url.path.hasSuffix("/all")
            ? #"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"900","title":"Book"}]}}"#
            : #"{"MediaContainer":{"size":0,"Directory":[]}}"#
        return HTTPResponse(status: 200, body: Data(json.utf8))
    }
}

private actor ChangingLibraryServer: HTTPClient {
    var page = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        defer { page += 1 }
        let json = page == 0
            ? #"{"MediaContainer":{"size":1,"totalSize":2,"Metadata":[{"ratingKey":"900","title":"First"}]}}"#
            : #"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"901","title":"Second"}]}}"#
        return HTTPResponse(status: 200, body: Data(json.utf8))
    }
}
