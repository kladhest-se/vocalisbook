import Foundation
import os
import Testing
import PlexKit
@testable import Audiobooks

/// Tier 2 was written and never called.
///
/// `ChapterResolver.fromEmbedded` was public, tested by its own arithmetic, and
/// referenced by nothing but a comment saying the app layer ought to call it.
/// The consequence was invisible in every existing test, because every existing
/// test asked the resolver directly rather than asking whether anything used it:
/// a single-file m4b fell past tier 2 to track boundaries and came out with one
/// chapter spanning thirty-three hours.
///
/// These go through `LibrarySync` for that reason. A test that calls
/// `fromEmbedded` again would pass on the tree that shipped the bug.
@Suite("Embedded chapters")
struct EmbeddedChapterTests {

    /// A book cached with whatever chapter list the test wants to start from.
    private func makeSync(
        segmentDurations: [Int],
        chapters: [Chapter]
    ) throws -> (LibrarySync, LibraryStore, AudiobookDatabase) {
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

        let tracks: [PlexTrack] = try segmentDurations.enumerated().map { index, duration in
            let json = """
            {"ratingKey":"t\(index)","key":"/library/metadata/t\(index)","title":"Part \(index + 1)",
             "index":\(index + 1),"duration":\(duration),
             "Media":[{"Part":[{"id":"p\(index)","key":"/library/parts/p\(index)/1/f.m4b","updatedAt":1}]}]}
            """
            return try JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
        }

        let library = LibraryStore(database: db)
        try library.cache(book: book, tracks: tracks, chapters: chapters, sectionID: "srv:2")

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
            transport: PlexTransport(client: SilentServer(), identity: .chapterTestIdentity)
        )
        let sync = LibrarySync(
            client: client,
            store: library,
            progress: SyncStore(database: db),
            downloadStore: DownloadStore(database: db),
            sectionID: "srv:2",
            sectionKey: "2"
        )
        return (sync, library, db)
    }

    private func urls(_ count: Int) -> [URL] {
        (0..<count).map { URL(string: "https://lan.plex.direct:32400/p\($0)")! }
    }

    /// The case from the screenshot: one file, one track-boundary chapter, and
    /// real chapter atoms inside it.
    @Test("A single-file book gets its embedded chapters")
    func singleFileUpgrades() async throws {
        let total = 33 * 3_600_000
        let (sync, library, _) = try makeSync(
            segmentDurations: [total],
            chapters: [Chapter(index: 0, title: "The whole book", startMs: 0, endMs: total, source: .trackBoundary)]
        )

        let upgraded = try await sync.upgradeChapters(
            ratingKey: "900",
            partURLs: urls(1),
            read: { _ in
                [(title: "One", startMs: 0, endMs: 1_000),
                 (title: "Two", startMs: 1_000, endMs: 2_000)]
            }
        )

        #expect(upgraded?.chapters.count == 2)
        #expect(upgraded?.chapters.first?.source == .embeddedInFile)
        #expect(upgraded?.chapters.last?.title == "Two")

        // And it is in the store, not merely returned.
        let reread = try library.timeline(bookRatingKey: "900")
        #expect(reread?.chapters.count == 2)
    }

    /// Offsets arrive relative to their own file and have to be shifted.
    @Test("A multi-file book's chapters are made book-absolute")
    func multiFileOffsetsShift() async throws {
        let (sync, _, _) = try makeSync(
            segmentDurations: [600_000, 600_000],
            chapters: ChapterResolver.fromTrackBoundaries(
                segments: [
                    .init(trackRatingKey: "t0", trackKey: "/t0", partID: "p0", partKey: "/p0",
                          partCacheKey: "c0", title: "Part 1", startMs: 0, durationMs: 600_000),
                    .init(trackRatingKey: "t1", trackKey: "/t1", partID: "p1", partKey: "/p1",
                          partCacheKey: "c1", title: "Part 2", startMs: 600_000, durationMs: 600_000),
                ]
            )
        )

        let upgraded = try await sync.upgradeChapters(
            ratingKey: "900",
            partURLs: urls(2),
            read: { _ in [(title: "A", startMs: 0, endMs: 300_000)] }
        )

        #expect(upgraded?.chapters.count == 2)
        #expect(upgraded?.chapters[0].startMs == 0)
        // The second file's chapter starts where the second file does.
        #expect(upgraded?.chapters[1].startMs == 600_000)
    }

    /// The guard that makes this safe to call on every open.
    @Test("A Plex-supplied list is never replaced")
    func plexListIsNotDowngraded() async throws {
        let (sync, _, _) = try makeSync(
            segmentDurations: [600_000],
            chapters: [Chapter(index: 0, title: "From Plex", startMs: 0, endMs: 600_000, source: .plexMetadata)]
        )

        let reads = ReadCounter()
        let upgraded = try await sync.upgradeChapters(
            ratingKey: "900",
            partURLs: urls(1),
            read: { _ in
                reads.bump()
                return [(title: "From the file", startMs: 0, endMs: 1_000)]
            }
        )

        #expect(upgraded == nil)
        // Not merely discarded afterwards — the file is never opened at all.
        #expect(reads.count == 0)
    }

    /// A file with no chapter atoms must leave the cached list alone rather than
    /// writing an empty one, which would read as "this book has no chapters".
    @Test("No atoms found leaves the existing chapters in place")
    func noAtomsKeepsExisting() async throws {
        let (sync, library, _) = try makeSync(
            segmentDurations: [600_000],
            chapters: [Chapter(index: 0, title: "Part 1", startMs: 0, endMs: 600_000, source: .trackBoundary)]
        )

        let upgraded = try await sync.upgradeChapters(
            ratingKey: "900", partURLs: urls(1), read: { _ in [] }
        )

        #expect(upgraded == nil)
        let reread = try library.timeline(bookRatingKey: "900")
        #expect(reread?.chapters.count == 1)
        #expect(reread?.chapters.first?.source == .trackBoundary)
    }

    /// Ninety MP3s is ninety range requests to improve on track boundaries that
    /// are already right for a book split into ninety MP3s.
    @Test("A book with more files than the cap is left alone")
    func manyFilesAreSkipped() async throws {
        let durations = Array(repeating: 60_000, count: 20)
        let (sync, _, _) = try makeSync(
            segmentDurations: durations,
            chapters: [Chapter(index: 0, title: "Part 1", startMs: 0, endMs: 60_000, source: .trackBoundary)]
        )

        let reads = ReadCounter()
        let upgraded = try await sync.upgradeChapters(
            ratingKey: "900",
            partURLs: urls(durations.count),
            maxSegments: 12,
            read: { _ in
                reads.bump()
                return [(title: "A", startMs: 0, endMs: 1_000)]
            }
        )

        #expect(upgraded == nil)
        #expect(reads.count == 0)
    }

    /// Chapter atoms are not obliged to carry a title, and a list of blank rows
    /// is worse than the one wrong row it replaced.
    @Test("Untitled chapters are numbered across the whole book")
    func untitledChaptersAreNumbered() {
        let numbered = LibrarySync.titled([
            Chapter(index: 0, title: "", startMs: 0, endMs: 100, source: .embeddedInFile),
            Chapter(index: 1, title: "Named", startMs: 100, endMs: 200, source: .embeddedInFile),
            Chapter(index: 2, title: "   ", startMs: 200, endMs: 300, source: .embeddedInFile),
        ])

        #expect(numbered[0].title == "Chapter 1")
        #expect(numbered[1].title == "Named")
        // Numbered by position in the book, not by position in its file.
        #expect(numbered[2].title == "Chapter 3")
    }
}

/// The network, which this suite never reaches: `upgradeChapters` reads the
/// cached timeline and the injected reader and nothing else. `LibrarySync`
/// requires a client to exist, so one is supplied that answers nothing.
private final class SilentServer: HTTPClient, @unchecked Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 200, body: Data("{}".utf8))
    }
}

/// Counts reader calls across an isolation boundary.
///
/// A captured `var` will not do: `read` is `@Sendable` and runs off this actor,
/// so mutating a local from inside it is the data race Swift 6 exists to reject.
private final class ReadCounter: @unchecked Sendable {
    /// `OSAllocatedUnfairLock`, not `NSLock`.
    ///
    /// This one compiled: its methods are synchronous, and the Swift 6
    /// restriction only bites when `lock()` is called from an async context.
    /// But `read` is an async closure, so making `bump` async — the obvious next
    /// edit — would have broken it, and the identical mistake in
    /// `IncrementalSyncTests` did break the build. One kind of lock in the tree
    /// is easier to hold to than a rule about where the other is safe.
    private let value = OSAllocatedUnfairLock(initialState: 0)

    func bump() {
        value.withLock { $0 += 1 }
    }

    var count: Int {
        value.withLock { $0 }
    }
}

extension PlexClientIdentity {
    fileprivate static let chapterTestIdentity = PlexClientIdentity(
        clientIdentifier: "TEST", product: "VocalisBook", version: "0.1.0",
        device: "Test", deviceName: "Test", platform: "test", platformVersion: "1"
    )
}
