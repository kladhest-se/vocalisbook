import Foundation
import Testing
import PlexKit
@testable import Audiobooks

@Suite("Downloads")
struct DownloadStoreTests {

    private func segments(_ count: Int, stamp: String = "1") -> [BookTimeline.Segment] {
        (0..<count).map { index in
            BookTimeline.Segment(
                trackRatingKey: "t\(index)",
                trackKey: "/library/metadata/t\(index)",
                partID: "p\(index)",
                partKey: "/library/parts/p\(index)/\(stamp)/f.mp3",
                partCacheKey: "p\(index)-\(stamp)",
                title: "Part \(index + 1)",
                startMs: index * 600_000,
                durationMs: 600_000
            )
        }
    }

    private func makeStore() throws -> (DownloadStore, AudiobookDatabase) {
        let db = try AudiobookDatabase.inMemory()
        return (DownloadStore(database: db), db)
    }

    @Test("A queued book reports as downloading, not as absent")
    func queuedIsInProgress() throws {
        let (store, _) = try makeStore()
        try store.enqueue(bookRatingKey: "900", segments: segments(3))

        let state = try store.state(bookRatingKey: "900")
        #expect(state.isActive)
        #expect(state.isComplete == false)
    }

    @Test("A book nobody asked for is not downloaded")
    func untouched() throws {
        let (store, _) = try makeStore()
        let state = try store.state(bookRatingKey: "900")
        #expect(state == .notDownloaded)
    }

    @Test("Each file counts for its share, whether or not its size is known")
    func progressAveragesFiles() throws {
        // Summing bytes across the book does not work: a file whose size is not
        // known yet contributes nothing to the denominator, so one finished file
        // out of four read as 100% — done and total were both that one file.
        let (store, _) = try makeStore()
        let parts = segments(4)
        try store.enqueue(bookRatingKey: "900", segments: parts)
        try store.markComplete(partCacheKey: parts[0].partCacheKey, relativePath: "a", bytes: 100)

        let state = try store.state(bookRatingKey: "900")
        guard case .downloading(let fraction) = state else {
            Issue.record("expected downloading, got \(state)")
            return
        }
        #expect(fraction == 0.25)
    }

    @Test("A file part-way through contributes part of its share")
    func partialFileCounts() throws {
        let (store, _) = try makeStore()
        let parts = segments(4)
        try store.enqueue(bookRatingKey: "900", segments: parts)
        try store.markComplete(partCacheKey: parts[0].partCacheKey, relativePath: "a", bytes: 100)
        try store.markDownloading(partCacheKey: parts[1].partCacheKey, bytesDone: 50, bytesTotal: 100)

        let state = try store.state(bookRatingKey: "900")
        guard case .downloading(let fraction) = state else {
            Issue.record("expected downloading, got \(state)")
            return
        }
        // One whole file and half of another, out of four.
        #expect(fraction == 0.375)
    }

    @Test("Nothing started reads as zero, not as absent")
    func nothingStarted() throws {
        // A queued book is not "not downloaded" — the button must show progress
        // rather than offering to start it again.
        let (store, _) = try makeStore()
        try store.enqueue(bookRatingKey: "900", segments: segments(4))

        let state = try store.state(bookRatingKey: "900")
        guard case .downloading(let fraction) = state else {
            Issue.record("expected downloading, got \(state)")
            return
        }
        #expect(fraction == 0)
    }

    @Test("Every file complete makes the book complete, with its size")
    func completeReportsSize() throws {
        let (store, _) = try makeStore()
        let parts = segments(2)
        try store.enqueue(bookRatingKey: "900", segments: parts)
        try store.markComplete(partCacheKey: parts[0].partCacheKey, relativePath: "a", bytes: 1_000)
        try store.markComplete(partCacheKey: parts[1].partCacheKey, relativePath: "b", bytes: 2_400)

        let state = try store.state(bookRatingKey: "900")
        #expect(state == .complete(bytes: 3_400))
        let total = try store.totalBytes()
        #expect(total == 3_400)
    }

    @Test("A retagged file queues afresh rather than counting as downloaded")
    func retaggedFileRequeues() throws {
        // The cache key is the part id and the file's updatedAt together, so a
        // book retagged on the server is a different set of files.
        let (store, _) = try makeStore()
        let old = segments(1, stamp: "1700000000")
        try store.enqueue(bookRatingKey: "900", segments: old)
        try store.markComplete(partCacheKey: old[0].partCacheKey, relativePath: "a", bytes: 500)
        let beforeRetag = try store.state(bookRatingKey: "900")
        #expect(beforeRetag.isComplete)

        let new = segments(1, stamp: "1800000000")
        try store.enqueue(bookRatingKey: "900", segments: new)
        let afterRetag = try store.state(bookRatingKey: "900")
        #expect(afterRetag.isComplete == false)
    }

    @Test("Evicting reports the files to delete and forgets the rows")
    func evictReturnsPaths() throws {
        // The store returns paths rather than deleting: it has no FileManager,
        // which is what lets it live in Core.
        let (store, _) = try makeStore()
        let parts = segments(2)
        try store.enqueue(bookRatingKey: "900", segments: parts)
        try store.markComplete(partCacheKey: parts[0].partCacheKey, relativePath: "a.audio", bytes: 1)
        try store.markComplete(partCacheKey: parts[1].partCacheKey, relativePath: "b.audio", bytes: 1)

        let paths = try store.evict(bookRatingKey: "900")
        #expect(paths.sorted() == ["a.audio", "b.audio"])
        let state = try store.state(bookRatingKey: "900")
        #expect(state == .notDownloaded)
        let total = try store.totalBytes()
        #expect(total == 0)
    }

    @Test("Only finished books are offered for clearing")
    func evictableNeedsFinishing() throws {
        let (store, db) = try makeStore()
        let sync = SyncStore(database: db)
        let parts = segments(1)

        try store.enqueue(bookRatingKey: "900", segments: parts)
        try store.markComplete(partCacheKey: parts[0].partCacheKey, relativePath: "a", bytes: 1)

        // Downloaded but still being listened to.
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 1_000)
        let whileListening = try store.evictableFinished()
        #expect(whileListening.isEmpty)

        try sync.markFinished(bookRatingKey: "900")
        let afterFinishing = try store.evictableFinished()
        #expect(afterFinishing == ["900"])
    }

    @Test("A failure surfaces rather than looking like progress")
    func failureIsVisible() throws {
        let (store, _) = try makeStore()
        let parts = segments(2)
        try store.enqueue(bookRatingKey: "900", segments: parts)
        try store.markFailed(partCacheKey: parts[0].partCacheKey, error: "connection refused")

        let state = try store.state(bookRatingKey: "900")
        #expect(state == .failed("connection refused"))
    }

    /// The Offline screen is built from this.
    ///
    /// It must list a book that is still transferring. `downloadedBooks` filters
    /// to parts already complete, which empties the screen at the one moment
    /// somebody opens it to watch a download — so this is a separate query
    /// rather than a filter on that one.
    @Test("Books with anything on disk include ones still downloading")
    func booksWithDownloadsIncludesInProgress() throws {
        let (store, _) = try makeStore()
        try store.enqueue(bookRatingKey: "900", segments: segments(2))
        try store.enqueue(bookRatingKey: "901", segments: segments(1, stamp: "2"))
        try store.markDownloading(partCacheKey: "p0-1", bytesDone: 10, bytesTotal: 100)

        let keys = try store.booksWithDownloads()
        #expect(Set(keys) == ["900", "901"])
    }

    @Test("A book is listed once however many parts it has")
    func booksWithDownloadsDeduplicates() throws {
        let (store, _) = try makeStore()
        try store.enqueue(bookRatingKey: "900", segments: segments(5))

        let keys = try store.booksWithDownloads()
        #expect(keys == ["900"])
    }

    @Test("Evicting a book removes it from the list")
    func evictedBooksLeaveTheList() throws {
        let (store, _) = try makeStore()
        try store.enqueue(bookRatingKey: "900", segments: segments(1))
        try store.enqueue(bookRatingKey: "901", segments: segments(1, stamp: "2"))

        _ = try store.evict(bookRatingKey: "900")

        let keys = try store.booksWithDownloads()
        #expect(keys == ["901"])
    }

    @Test("Nothing downloaded is an empty list, not an error")
    func nothingDownloaded() throws {
        let (store, _) = try makeStore()
        // Hoisted, per the note at the top of this file: the macro expands its
        // argument into a closure, so a `try` written inside it is reported
        // against generated code rather than against this line.
        let keys = try store.booksWithDownloads()
        #expect(keys.isEmpty)
    }

    /// A view polls while a download can still change by itself, and not
    /// otherwise. Getting this backwards means either a stuck progress bar or a
    /// timer running for the life of the app.
    @Test("Only a live transfer is unsettled")
    func settledStates() {
        #expect(BookDownloadState.downloading(fraction: 0.5).isSettled == false)
        #expect(BookDownloadState.notDownloaded.isSettled)
        #expect(BookDownloadState.complete(bytes: 1).isSettled)
        #expect(BookDownloadState.failed("nope").isSettled)
    }
}

