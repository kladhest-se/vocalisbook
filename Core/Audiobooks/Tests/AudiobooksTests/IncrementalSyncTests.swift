import Foundation
import os
import Testing
import PlexKit
@testable import Audiobooks

/// Every refresh used to page the whole library from zero. Fine for fifty books;
/// twenty requests and a visible wait for several thousand.
@Suite("Incremental sync")
struct IncrementalSyncTests {

    private func makeSync() throws -> (LibrarySync, LibraryStore, RecordingServer, AudiobookDatabase) {
        let db = try AudiobookDatabase.inMemory()

        try db.writer.write { conn in
            let server = ServerRecord(
                machineIdentifier: "srv", name: "test",
                lastConnectedURI: nil, lastConnectedAt: nil, lastConnectionWasRelay: false
            )
            try server.insert(conn)
            let section = LibrarySectionRecord(
                id: "srv:2", serverID: "srv", sectionKey: "2",
                title: "Audiobooks", lastSyncedAt: nil
            )
            try section.insert(conn)
        }

        let library = LibraryStore(database: db)
        let stub = RecordingServer()
        let connection = ResolvedConnection(
            serverIdentifier: "srv",
            baseURL: URL(string: "https://lan.plex.direct:32400")!,
            accessToken: "tok",
            isLocal: true,
            isRelay: false,
            resolvedAt: Date(),
            probeLatency: .milliseconds(1)
        )
        let client = PlexServerClient(
            connection: connection,
            transport: PlexTransport(client: stub, identity: .syncTestIdentity)
        )
        let sync = LibrarySync(
            client: client,
            store: library,
            progress: SyncStore(database: db),
            downloadStore: DownloadStore(database: db),
            sectionID: "srv:2",
            sectionKey: "2"
        )
        return (sync, library, stub, db)
    }

    /// The stamp is what makes the next sync incremental, so writing it at the
    /// wrong moment is the whole failure mode.
    @Test("Picking a library does not claim it has been synced")
    func pickingDoesNotStamp() throws {
        let (_, library, _, _) = try makeSync()

        let section = try JSONDecoder().decode(PlexLibrarySection.self, from: Data("""
        {"key":"2","title":"Audiobooks","type":"artist"}
        """.utf8))
        try library.upsert(section: section, serverID: "srv")

        // It used to stamp `now` here — which is when somebody *chose* a
        // library, not when one was fetched. An incremental sync reading that
        // would skip the entire first fetch.
        let stamp = try library.lastSynced(sectionID: "srv:2")
        #expect(stamp == nil)
    }

    @Test("Re-picking a library keeps the stamp it already had")
    func repickingPreservesTheStamp() throws {
        let (_, library, _, _) = try makeSync()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try library.markSynced(sectionID: "srv:2", at: when)

        let section = try JSONDecoder().decode(PlexLibrarySection.self, from: Data("""
        {"key":"2","title":"Audiobooks","type":"artist"}
        """.utf8))
        try library.upsert(section: section, serverID: "srv")

        let stamp = try library.lastSynced(sectionID: "srv:2")
        #expect(stamp == when)
    }

    /// Nothing to be incremental about, so it asks for everything.
    @Test("The first sync is full even when asked to be incremental")
    func firstSyncIsFull() async throws {
        let (sync, _, stub, _) = try makeSync()
        stub.pages = [[]]

        try await sync.refreshBooks(incremental: true)

        // The page requests only. A full sync also asks for the Mood directory
        // now, to fill in series tags the album list does not carry — so a bare
        // count of every request this made stopped being a statement about
        // paging the moment that was added.
        let pages = stub.requestedURLs.filter { $0.contains("/all") }
        #expect(pages.count == 1)
        #expect(pages.first?.contains("updatedAt") == false)
    }

    @Test("A later sync asks only for what changed")
    func laterSyncFilters() async throws {
        let (sync, library, stub, _) = try makeSync()
        stub.pages = [[]]
        try library.markSynced(sectionID: "srv:2", at: Date(timeIntervalSince1970: 1_700_000_000))

        try await sync.refreshBooks(incremental: true)

        let url = try #require(stub.requestedURLs.first)
        // The comparison lives in the parameter name, and the value is whole
        // seconds — some server versions ignore a fractional one and quietly
        // return everything.
        #expect(url.contains("updatedAt"))
        #expect(url.contains("1700000000"))
    }

    @Test("A full sync never sends the filter, however recently it synced")
    func fullSyncIgnoresTheStamp() async throws {
        let (sync, library, stub, _) = try makeSync()
        stub.pages = [[]]
        try library.markSynced(sectionID: "srv:2", at: Date(timeIntervalSince1970: 1_700_000_000))

        try await sync.refreshBooks(incremental: false)

        // The page request, named rather than taken as the first one. A full
        // sync makes more than one request now, and `first` passing depends on
        // which order they happen to go out in.
        let pages = stub.requestedURLs.filter { $0.contains("/all") }
        #expect(pages.first?.contains("updatedAt") == false)
    }

    /// Taken before the request, not after the last page.
    ///
    /// A stamp written at the end marks everything that changed *during* the
    /// sync as already seen, and those books are then never fetched again — a
    /// book edited while a long sync runs would be missing until something paged
    /// the whole library.
    @Test("The stamp is the moment the sync began")
    func stampIsTakenAtTheStart() async throws {
        let (sync, library, stub, _) = try makeSync()
        stub.pages = [[]]

        let before = Date()
        try await sync.refreshBooks()
        let after = Date()

        let recorded = try library.lastSynced(sectionID: "srv:2")
        let stamp = try #require(recorded)

        // A millisecond of slack in each direction, because the stamp has been
        // through SQLite. GRDB stores a `Date` as a string with millisecond
        // resolution, so a value captured at `.5674` comes back as `.567` —
        // fractionally *before* the `Date()` taken a moment earlier in this
        // test. The first version compared exactly and failed on that, which
        // says nothing about when the stamp was taken and everything about
        // storage precision.
        let slack: TimeInterval = 0.001
        #expect(stamp >= before.addingTimeInterval(-slack))
        #expect(stamp <= after.addingTimeInterval(slack))
    }
    /// A refresh brings metadata and nothing else.
    ///
    /// Plex tracks progress within a file; which books are on the go is the
    /// client's own state, synced between devices by iCloud. A refresh that also
    /// read the server's positions was overwriting the app's record with a copy
    /// of it — which is why clearing the cache appeared not to work, the rows
    /// coming straight back on the next sync.
    @Test("A refresh does not ask the server what was played")
    func refreshDoesNotReadPositions() async throws {
        let (sync, library, stub, _) = try makeSync()
        try library.markSynced(sectionID: "srv:2", at: Date(timeIntervalSince1970: 1_000))

        _ = try? await sync.refreshBooks(incremental: true)

        #expect(!stub.requestedURLs.contains { $0.contains("lastViewedAt") })
    }

    /// And a position already on the device is not replaced by the server's.
    @Test("A refresh leaves local positions alone")
    func refreshLeavesPositionsAlone() async throws {
        let (sync, library, stub, db) = try makeSync()
        let progress = SyncStore(database: db)

        stub.pages = [[
            """
            {"ratingKey":"900","title":"A Hat Full of Sky","type":"album",
             "viewOffset":900000,"lastViewedAt":\(Int(Date().timeIntervalSince1970))}
            """
        ]]

        try progress.recordPosition(bookRatingKey: "900", absoluteMs: 60_000)
        _ = try? await sync.refreshBooks()

        let stored = try progress.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 60_000)

        _ = library
    }
}

/// Records what was asked for, and answers with the pages it was given.
///
/// `OSAllocatedUnfairLock` rather than `NSLock`, and the scoped `withLock` form
/// rather than a lock/unlock pair. Swift 6 marks `NSLock.lock()` and `unlock()`
/// unavailable from asynchronous contexts, and `send` is `async` — so the
/// obvious version does not compile at all.
///
/// `StubHTTPClient` in PlexKit's tests carries this same note, which is where it
/// should have been read from. A rule living in a comment beside the first place
/// it was learned is a rule the second place never sees; `contract.sh` checks it
/// now.
private final class RecordingServer: HTTPClient, @unchecked Sendable {

    private struct State: Sendable {
        var urls: [String] = []
        var pages: [[String]] = []
        var index = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var pages: [[String]] {
        get { state.withLock { $0.pages } }
        set { state.withLock { current in current.pages = newValue; current.index = 0 } }
    }

    var requestedURLs: [String] {
        state.withLock { $0.urls }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let page: [String] = state.withLock { current in
            current.urls.append(request.url.absoluteString)
            let page = current.index < current.pages.count ? current.pages[current.index] : []
            current.index += 1
            return page
        }

        let json = """
        {"MediaContainer":{"size":\(page.count),"totalSize":\(page.count),
         "Metadata":[\(page.joined(separator: ","))]}}
        """
        return HTTPResponse(status: 200, body: Data(json.utf8))
    }
}

extension PlexClientIdentity {
    fileprivate static let syncTestIdentity = PlexClientIdentity(
        clientIdentifier: "TEST", product: "VocalisBook", version: "0.1.0",
        device: "Test", deviceName: "Test", platform: "test", platformVersion: "1"
    )
}
