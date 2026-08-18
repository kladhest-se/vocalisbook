import Foundation
import os
import Testing
@testable import Audiobooks
@testable import PlexKit

/// Filling in series from Plex's own tag directory.
///
/// This exists because the album list endpoint carries no Moods — only the
/// per-book detail does — so a library refresh caches every book and no series.
/// Plex will list its tags, which is one request for the directory and one per
/// series rather than one per book.
@Suite("Series tags")
struct SeriesTagsTests {

    /// Answers the two requests this needs, and counts them.
    ///
    /// The count is part of what is being tested: the point of going through the
    /// tag directory rather than the books is that the work scales with the
    /// number of series, and a change that quietly made it per-book would still
    /// produce the right rows.
    private final class TagServer: HTTPClient, @unchecked Sendable {
        var moodsJSON = ""
        var booksByMood: [String: String] = [:]
        private(set) var requests: [String] = []

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let url = request.url.absoluteString
            requests.append(url)

            if url.contains("/mood") && !url.contains("mood=") {
                return HTTPResponse(status: 200, body: Data(moodsJSON.utf8))
            }

            // `mood=<key>` names which tag's books are wanted.
            if let range = url.range(of: "mood=") {
                let key = String(url[range.upperBound...].prefix { $0.isNumber })
                return HTTPResponse(status: 200, body: Data((booksByMood[key] ?? "").utf8))
            }

            return HTTPResponse(status: 200, body: Data("{}".utf8))
        }
    }

    private func makeSync(_ server: TagServer) throws -> (LibrarySync, LibraryStore, AudiobookDatabase) {
        let db = try AudiobookDatabase.inMemory()

        try db.writer.write { conn in
            let record = ServerRecord(
                machineIdentifier: "srv", name: "test",
                lastConnectedURI: nil, lastConnectedAt: nil, lastConnectionWasRelay: false
            )
            try record.insert(conn)
            let section = LibrarySectionRecord(
                id: "srv:2", serverID: "srv", sectionKey: "2",
                title: "Audiobooks", lastSyncedAt: nil
            )
            try section.insert(conn)
        }

        let library = LibraryStore(database: db)

        // The books have to be cached already: a tag names a book, and a row
        // pointing at a book this device does not have would fail its foreign
        // key. This is the order a real refresh uses too — pages first, tags
        // after.
        let books = try ["900", "901", "902"].map { key -> PlexBook in
            let json = """
            {"ratingKey":"\(key)","title":"Book \(key)","parentTitle":"An Author"}
            """
            return try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        }
        try library.cacheBookList(books, sectionID: "srv:2")

        // Built the way the other suites build it, rather than the way I first
        // guessed: `ResolvedConnection`, and the identity belongs to the
        // transport rather than the client.
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
            transport: PlexTransport(client: server, identity: .seriesTestIdentity)
        )

        return (
            LibrarySync(
                client: client,
                store: library,
                progress: SyncStore(database: db),
                downloadStore: DownloadStore(database: db),
                sectionID: "srv:2",
                sectionKey: "2"
            ),
            library,
            db
        )
    }

    private func moods(_ entries: [(key: String, title: String)]) -> String {
        let items = entries
            .map { "{\"key\":\"\($0.key)\",\"title\":\"\($0.title)\"}" }
            .joined(separator: ",")
        return "{\"MediaContainer\":{\"size\":\(entries.count),\"Directory\":[\(items)]}}"
    }

    private func books(_ keys: [String]) -> String {
        let items = keys
            .map { "{\"ratingKey\":\"\($0)\",\"title\":\"Book \($0)\"}" }
            .joined(separator: ",")
        return "{\"MediaContainer\":{\"size\":\(keys.count),\"Metadata\":[\(items)]}}"
    }

    @Test("Series and sequence tags become rows")
    func writesSeriesAndSequences() async throws {
        let server = TagServer()
        server.moodsJSON = moods([
            (key: "1", title: "Series: Dune"),
            (key: "2", title: "Sequence: Dune #1"),
            (key: "3", title: "Sequence: Dune #2"),
        ])
        server.booksByMood = [
            "1": books(["900", "901"]),
            "2": books(["900"]),
            "3": books(["901"]),
        ]

        let (sync, library, _) = try makeSync(server)
        _ = try await sync.refreshSeriesTags()

        let series = try library.series(sectionID: "srv:2")
        #expect(series.map(\.name) == ["Dune"])
        #expect(series.first?.bookCount == 2)

        let entries = try library.books(inSeries: "Dune")
        #expect(entries.map(\.book.ratingKey) == ["900", "901"])
        #expect(entries.map(\.position) == ["1", "2"])
    }

    /// Only the two prefixes it can use.
    ///
    /// A library's Moods are mostly author names, and `Language:` and `Edition:`
    /// are in there too. Fetching the books under each of those would be a
    /// request per author for nothing.
    @Test("Author, language and edition tags are not fetched")
    func skipsOtherMoods() async throws {
        let server = TagServer()
        server.moodsJSON = moods([
            (key: "1", title: "Series: Dune"),
            (key: "2", title: "Frank Herbert"),
            (key: "3", title: "Language: English"),
            (key: "4", title: "Edition: Unabridged"),
        ])
        server.booksByMood = ["1": books(["900"])]

        let (sync, _, _) = try makeSync(server)
        _ = try await sync.refreshSeriesTags()

        let fetched = server.requests.filter { $0.contains("mood=") }
        #expect(fetched.count == 1)
        #expect(fetched.first?.contains("mood=1") == true)
    }

    /// One request for the directory, then one per series tag — not one per
    /// book, which is the reason this goes through the tag directory at all.
    @Test("Requests scale with series, not with books")
    func requestCount() async throws {
        let server = TagServer()
        server.moodsJSON = moods([
            (key: "1", title: "Series: Dune"),
            (key: "2", title: "Series: Discworld"),
        ])
        server.booksByMood = [
            "1": books(["900", "901"]),
            "2": books(["902"]),
        ]

        let (sync, _, _) = try makeSync(server)
        _ = try await sync.refreshSeriesTags()

        // The directory, plus one per tag. Three books are involved and none of
        // them was asked about individually.
        #expect(server.requests.count == 3)
    }

    /// Progress is reported so a screen can say what is happening, and the total
    /// is known before the work starts rather than climbing as it goes.
    @Test("Progress is reported against a total known up front")
    func reportsProgress() async throws {
        let server = TagServer()
        server.moodsJSON = moods([
            (key: "1", title: "Series: Dune"),
            (key: "2", title: "Series: Discworld"),
            (key: "3", title: "An Author"),
        ])
        server.booksByMood = ["1": books(["900"]), "2": books(["901"])]

        let (sync, _, _) = try makeSync(server)

        let reports = SeriesProgressReports()
        _ = try await sync.refreshSeriesTags { done, total in
            reports.add(done: done, total: total)
        }

        let seen = reports.all
        #expect(seen.first?.total == 2)
        #expect(seen.allSatisfy { $0.total == 2 })
        #expect(seen.last?.done == 2)
    }

    /// A tag the server will not answer about does not stop the others.
    @Test("One failing tag does not lose the rest")
    func oneFailureDoesNotStopTheSweep() async throws {
        let server = TagServer()
        server.moodsJSON = moods([
            (key: "1", title: "Series: Dune"),
            (key: "2", title: "Series: Discworld"),
        ])
        // Only one answers with anything decodable.
        server.booksByMood = ["2": books(["902"])]

        let (sync, library, _) = try makeSync(server)
        _ = try await sync.refreshSeriesTags()

        let series = try library.series(sectionID: "srv:2")
        #expect(series.contains { $0.name == "Discworld" })
    }

    /// A tag naming a book this device has not cached is ignored rather than
    /// failing the sweep — the row would have nothing to point at.
    @Test("A tag for an uncached book is skipped")
    func uncachedBookIsSkipped() async throws {
        let server = TagServer()
        server.moodsJSON = moods([(key: "1", title: "Series: Dune")])
        server.booksByMood = ["1": books(["900", "999"])]

        let (sync, library, _) = try makeSync(server)
        _ = try await sync.refreshSeriesTags()

        let entries = try library.books(inSeries: "Dune")
        #expect(entries.map(\.book.ratingKey) == ["900"])
    }
}

/// Collects progress callbacks, which arrive from a `@Sendable` closure.
///
/// `OSAllocatedUnfairLock` rather than `NSLock`, which is what this project
/// uses everywhere else — and `contract.sh` says so when it is not.
///
/// Named `SeriesProgressReports` rather than `Reports`: a `private` type in a
/// test file still shares a module with everything else, and something short
/// enough to collide will.
private final class SeriesProgressReports: Sendable {
    private let values = OSAllocatedUnfairLock<[(done: Int, total: Int)]>(initialState: [])

    func add(done: Int, total: Int) {
        values.withLock { $0.append((done, total)) }
    }

    var all: [(done: Int, total: Int)] {
        values.withLock { $0 }
    }
}

extension PlexClientIdentity {
    fileprivate static let seriesTestIdentity = PlexClientIdentity(
        clientIdentifier: "TEST", product: "VocalisBook", version: "0.1.0",
        device: "Test", deviceName: "Test", platform: "test", platformVersion: "1"
    )
}
