import Foundation
import Testing
@testable import Audiobooks

/// A book that says it is downloaded, playing over the network.
///
/// `state` counted every record filed under the book, and playback resolves a
/// file by *part cache key*. When that key gained a fallback for servers that
/// send no `updatedAt`, every book downloaded before the change kept complete
/// records under its old keys — so the screen showed a tick and a size while
/// playback looked up the new key, found nothing, and streamed. Nothing on
/// screen said which was happening.
@Suite("Download state against the current book")
struct DownloadStateTests {

    private func makeStore() throws -> (DownloadStore, AudiobookDatabase) {
        let db = try AudiobookDatabase.inMemory()
        return (DownloadStore(database: db), db)
    }

    /// Records are created by enqueueing the book's segments and then completing
    /// them, which is the path the coordinator takes.
    private func record(
        _ store: DownloadStore,
        book: String = "900",
        partKey: String,
        path: String
    ) throws {
        let segment = BookTimeline.Segment(
            trackRatingKey: "t-\(partKey)",
            trackKey: "/library/metadata/t-\(partKey)",
            partID: "p-\(partKey)",
            partKey: "/library/parts/\(partKey)",
            partCacheKey: partKey,
            title: "Part",
            startMs: 0,
            durationMs: 600_000
        )
        try store.enqueue(bookRatingKey: book, segments: [segment])
        try store.markComplete(partCacheKey: partKey, relativePath: path, bytes: 1_000)
    }

    private let alwaysThere: (String) -> Bool = { _ in true }

    @Test("A book whose parts are all present is downloaded")
    func complete() throws {
        let (store, _) = try makeStore()
        try record(store, partKey: "p1-s100", path: "p1-s100.m4b")
        try record(store, partKey: "p2-s200", path: "p2-s200.m4b")

        let state = try store.state(
            bookRatingKey: "900",
            partCacheKeys: ["p1-s100", "p2-s200"],
            fileExists: alwaysThere
        )
        #expect(state.isComplete)
    }

    /// The bug. Records exist, files exist, and none of them are for the parts
    /// this book now asks for.
    @Test("Records under old cache keys do not count as downloaded")
    func staleKeys() throws {
        let (store, _) = try makeStore()
        try record(store, partKey: "p1-0", path: "p1-0.audio")
        try record(store, partKey: "p2-0", path: "p2-0.audio")

        let state = try store.state(
            bookRatingKey: "900",
            partCacheKeys: ["p1-s100", "p2-s200"],
            fileExists: alwaysThere
        )
        #expect(state == .notDownloaded)
    }

    /// Half-migrated is not downloaded either: without this, a book with one new
    /// key and one old one reports on the half it happens to have.
    @Test("A part with no record at all means not downloaded")
    func missingOnePart() throws {
        let (store, _) = try makeStore()
        try record(store, partKey: "p1-s100", path: "p1-s100.m4b")

        let state = try store.state(
            bookRatingKey: "900",
            partCacheKeys: ["p1-s100", "p2-s200"],
            fileExists: alwaysThere
        )
        #expect(state == .notDownloaded)
    }

    /// A record outlives the file it describes: a failed move, a restore from
    /// backup, or somebody with a Finder window.
    @Test("A complete record with no file is not downloaded")
    func missingFile() throws {
        let (store, _) = try makeStore()
        try record(store, partKey: "p1-s100", path: "p1-s100.m4b")

        let state = try store.state(
            bookRatingKey: "900",
            partCacheKeys: ["p1-s100"],
            fileExists: { _ in false }
        )
        #expect(state == .notDownloaded)
    }

    /// The loose form still works, for callers that only want a progress figure
    /// and have no timeline yet.
    @Test("Without keys or a file check, the old answer is unchanged")
    func looseFormUnchanged() throws {
        let (store, _) = try makeStore()
        try record(store, partKey: "p1-0", path: "p1-0.audio")

        let state = try store.state(bookRatingKey: "900")
        #expect(state.isComplete)
    }

    // MARK: - Reclaiming

    @Test("Stale records are dropped and current ones kept")
    func discardStale() throws {
        let (store, _) = try makeStore()
        try record(store, partKey: "p1-0", path: "p1-0.audio")
        try record(store, partKey: "p1-s100", path: "p1-s100.m4b")

        let dropped = try store.discardStale(bookRatingKey: "900", keeping: ["p1-s100"])
        #expect(dropped == 1)

        // What is left is exactly what the book asks for, so its file is the
        // only one still referenced — the launch sweep reclaims the other.
        let paths = try store.allRelativePaths()
        #expect(paths == ["p1-s100.m4b"])
    }

    @Test("Another book's records are left alone")
    func discardIsPerBook() throws {
        let (store, _) = try makeStore()
        try record(store, book: "900", partKey: "p1-0", path: "p1-0.audio")
        try record(store, book: "901", partKey: "q1-0", path: "q1-0.audio")

        try store.discardStale(bookRatingKey: "900", keeping: ["p1-s100"])

        let paths = try store.allRelativePaths()
        #expect(paths == ["q1-0.audio"])
    }
}
