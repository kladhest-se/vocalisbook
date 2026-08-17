import Foundation
import Testing
import PlexKit
@testable import Audiobooks

/// Plex has no book-level position.
///
/// For a single-file book the album's `viewOffset` happens to be it. For
/// everything else the position is scattered across the tracks, and reassembling
/// it is the only way a second device can pick up where the first left off. The
/// version before this returned nil for anything with more than one file —
/// nearly every audiobook — so the phone reported its position correctly and the
/// Mac started from zero.
@Suite("Remote position")
struct RemotePositionTests {

    /// A stub server returning one book and its tracks.
    private func makeSync(
        segmentDurations: [Int],
        trackState: [(offset: Int?, viewCount: Int?, lastViewed: Int?)]
    ) throws -> (ProgressSync, LibraryStore, AudiobookDatabase) {
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

        let bookJSON = """
        {"ratingKey":"900","title":"A Book","parentTitle":"An Author"}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(bookJSON.utf8))

        let plexTracks: [PlexTrack] = try segmentDurations.enumerated().map { index, duration in
            let json = """
            {"ratingKey":"t\(index)","key":"/library/metadata/t\(index)","title":"Part \(index + 1)",
             "index":\(index + 1),"duration":\(duration),
             "Media":[{"Part":[{"id":"p\(index)","key":"/library/parts/p\(index)/1/f.mp3","updatedAt":1}]}]}
            """
            return try JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
        }

        let library = LibraryStore(database: db)
        try library.cache(book: book, tracks: plexTracks, chapters: [], sectionID: "srv:2")

        // The same tracks as the server would report them, now carrying
        // whatever listening state the test is describing.
        let serverTracks = segmentDurations.enumerated().map { index, duration -> String in
            let state = trackState[index]
            var fields = """
            "ratingKey":"t\(index)","key":"/library/metadata/t\(index)","title":"Part \(index + 1)",
            "index":\(index + 1),"duration":\(duration)
            """
            if let offset = state.offset { fields += ",\"viewOffset\":\(offset)" }
            if let count = state.viewCount { fields += ",\"viewCount\":\(count)" }
            if let seen = state.lastViewed { fields += ",\"lastViewedAt\":\(seen)" }
            return "{\(fields),\"Media\":[{\"Part\":[{\"id\":\"p\(index)\",\"key\":\"/p\",\"updatedAt\":1}]}]}"
        }

        let stub = StubServer()
        stub.tracksJSON = "{\"MediaContainer\":{\"size\":\(serverTracks.count),\"Metadata\":[\(serverTracks.joined(separator: ","))]}}"
        stub.bookJSON = "{\"MediaContainer\":{\"size\":1,\"Metadata\":[\(bookJSON)]}}"

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
            transport: PlexTransport(client: stub, identity: .testIdentity)
        )
        return (ProgressSync(client: client, store: SyncStore(database: db), library: library), library, db)
    }

    @Test("A multi-file book reassembles its position from the tracks")
    func multiFileReassembles() async throws {
        // Two tracks finished, the third half way through.
        let (sync, _, _) = try makeSync(
            segmentDurations: [600_000, 600_000, 600_000],
            trackState: [
                (offset: nil, viewCount: 1, lastViewed: 1_700_000_000),
                (offset: nil, viewCount: 1, lastViewed: 1_700_000_100),
                (offset: 300_000, viewCount: nil, lastViewed: 1_700_000_200),
            ]
        )
        let remote = try await sync.remotePosition(bookRatingKey: "900")
        #expect(remote.absoluteMs == 1_500_000)
        #expect(remote.changedAt == Date(timeIntervalSince1970: 1_700_000_200))
    }

    @Test("A book nobody has started has no remote position")
    func untouchedIsNil() async throws {
        let (sync, _, _) = try makeSync(
            segmentDurations: [600_000, 600_000],
            trackState: [(nil, nil, nil), (nil, nil, nil)]
        )
        let remote = try await sync.remotePosition(bookRatingKey: "900")
        #expect(remote.absoluteMs == nil)
    }

    @Test("A finished track behind a half-played one does not drag progress back")
    func furthestWins() async throws {
        // Re-listening to track 1 leaves an offset there while track 3 is done.
        let (sync, _, _) = try makeSync(
            segmentDurations: [600_000, 600_000, 600_000],
            trackState: [
                (offset: 120_000, viewCount: 1, lastViewed: 1_700_000_300),
                (offset: nil, viewCount: 1, lastViewed: 1_700_000_100),
                (offset: nil, viewCount: 1, lastViewed: 1_700_000_200),
            ]
        )
        let remote = try await sync.remotePosition(bookRatingKey: "900")
        #expect(remote.absoluteMs == 1_800_000, "the end of the last finished track")
    }

    @Test("An offset longer than its track is clamped, not trusted")
    func offsetClamped() async throws {
        // Reachable when a file is re-encoded shorter than the position Plex
        // still holds for it.
        //
        // This case is also what caught the single-file shortcut: the earlier
        // version read the album's viewOffset for a one-track book and never
        // reached the clamp at all.
        let (sync, _, _) = try makeSync(
            segmentDurations: [600_000],
            trackState: [(offset: 99_000_000, viewCount: nil, lastViewed: 1_700_000_000)]
        )
        let remote = try await sync.remotePosition(bookRatingKey: "900")
        #expect(remote.absoluteMs == 600_000)
    }

    @Test("A single-file book reads its position from its one track")
    func singleFileOrdinary() async throws {
        let (sync, _, _) = try makeSync(
            segmentDurations: [600_000],
            trackState: [(offset: 250_000, viewCount: nil, lastViewed: 1_700_000_000)]
        )
        let remote = try await sync.remotePosition(bookRatingKey: "900")
        #expect(remote.absoluteMs == 250_000)
    }

    @Test("A finished single-file book reads as complete")
    func singleFileFinished() async throws {
        let (sync, _, _) = try makeSync(
            segmentDurations: [600_000],
            trackState: [(offset: nil, viewCount: 1, lastViewed: 1_700_000_000)]
        )
        let remote = try await sync.remotePosition(bookRatingKey: "900")
        #expect(remote.absoluteMs == 600_000)
    }

    @Test("A book with no cached timeline reports nothing rather than guessing")
    func noTimeline() async throws {
        let (sync, _, _) = try makeSync(segmentDurations: [600_000], trackState: [(nil, nil, nil)])
        let remote = try await sync.remotePosition(bookRatingKey: "nope")
        #expect(remote.absoluteMs == nil)
        #expect(remote.changedAt == nil)
    }

    /// The sweep over the active list.
    ///
    /// The list is the client's — this device's, and the other devices' through
    /// iCloud. Plex is asked about the books on it, one at a time, and this is
    /// where the two meet.
    @Test("A book Plex has fully played leaves the list")
    func finishedOnServerLeavesTheList() async throws {
        // Every track played, which is the only thing Plex has to say a book is
        // done: there is no "finished" on an album.
        let (sync, library, db) = try makeSync(
            segmentDurations: [600_000, 600_000],
            trackState: [
                (offset: nil, viewCount: 1, lastViewed: 1_700_000_100),
                (offset: nil, viewCount: 1, lastViewed: 1_700_000_200),
            ]
        )
        let store = SyncStore(database: db)
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 300_000)

        let before = try library.continueListening()
        #expect(before.contains { $0.ratingKey == "900" })

        await sync.refreshActive(bookRatingKeys: ["900"])

        let after = try library.continueListening()
        #expect(!after.contains { $0.ratingKey == "900" })
    }

    /// Somebody listened further on another client, and this device catches up.
    @Test("A position further along on the server is adopted")
    func furtherOnServerIsAdopted() async throws {
        let (sync, _, db) = try makeSync(
            segmentDurations: [600_000, 600_000],
            trackState: [
                (offset: nil, viewCount: 1, lastViewed: 1_700_000_100),
                (offset: 300_000, viewCount: nil, lastViewed: 1_700_000_200),
            ]
        )
        let store = SyncStore(database: db)

        // Seeded as *already pushed*, which is the state the sweep runs in:
        // `refreshActiveBooks` drains the outbox before it checks, so anything
        // this device did is on the server by then.
        //
        // Recording it with `recordPosition` instead — as this test first did —
        // leaves it unsent, so both sides have moved since the last sync and the
        // answer is a conflict rather than an adoption. That is the correct
        // outcome for those inputs, and the test was asserting against the rule
        // rather than against a bug.
        try store.adoptRemote(
            bookRatingKey: "900",
            absoluteMs: 60_000,
            at: Date(timeIntervalSince1970: 1_600_000_000)
        )

        await sync.refreshActive(bookRatingKeys: ["900"])

        let stored = try store.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 900_000)
    }

    /// Both sides moved since the last sync, and the sweep leaves it alone.
    ///
    /// A conflict is never resolved silently — losing an hour of somebody's
    /// place is the one failure this app is not forgiven for — and a background
    /// sweep is the last place to start guessing. The book screen asks when it
    /// is opened.
    @Test("A conflict is left for the book screen, not resolved in the sweep")
    func conflictIsLeftAlone() async throws {
        let (sync, _, db) = try makeSync(
            segmentDurations: [600_000, 600_000],
            trackState: [
                (offset: nil, viewCount: 1, lastViewed: 1_700_000_100),
                (offset: 300_000, viewCount: nil, lastViewed: 1_700_000_200),
            ]
        )
        let store = SyncStore(database: db)

        // Listened to here and not yet pushed, while the server also moved.
        try store.recordPosition(
            bookRatingKey: "900",
            absoluteMs: 60_000,
            at: Date(timeIntervalSince1970: 1_600_000_000)
        )

        await sync.refreshActive(bookRatingKeys: ["900"])

        let stored = try store.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 60_000)
    }

    /// A book nobody has finished and nobody has moved stays as it is.
    @Test("An unfinished book with nothing new is left alone")
    func unchangedBookIsLeftAlone() async throws {
        let (sync, library, db) = try makeSync(
            segmentDurations: [600_000, 600_000],
            trackState: [
                (offset: 120_000, viewCount: nil, lastViewed: 1_600_000_000),
                (offset: nil, viewCount: nil, lastViewed: nil),
            ]
        )
        let store = SyncStore(database: db)
        try store.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)

        await sync.refreshActive(bookRatingKeys: ["900"])

        let listed = try library.continueListening()
        #expect(listed.contains { $0.ratingKey == "900" })

        let stored = try store.progress(bookRatingKey: "900")
        let after = try #require(stored)
        #expect(after.absoluteMs == 120_000)
    }
}

/// Minimal stand-in for the network, answering the two calls this needs.
private final class StubServer: HTTPClient, @unchecked Sendable {
    var tracksJSON = ""
    var bookJSON = ""

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url.absoluteString
        if url.contains("/children") {
            return HTTPResponse(status: 200, body: Data(tracksJSON.utf8))
        }
        return HTTPResponse(status: 200, body: Data(bookJSON.utf8))
    }
}

extension PlexClientIdentity {
    fileprivate static let testIdentity = PlexClientIdentity(
        clientIdentifier: "TEST", product: "VocalisBook", version: "0.1.0",
        device: "Test", deviceName: "Test", platform: "test", platformVersion: "1"
    )
}
