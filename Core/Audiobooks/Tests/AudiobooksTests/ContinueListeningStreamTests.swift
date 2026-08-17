import Foundation
import Testing
import GRDB
@testable import Audiobooks
@testable import PlexKit

/// The observed Continue listening list.
///
/// This is the mechanism that replaced thirty-four writers each having to
/// remember to signal the screen. It is worth testing precisely because its
/// failure mode is the old one: silence. A stream that stops delivering looks
/// exactly like a list that has not changed.
@Suite("Continue listening observation")
struct ContinueListeningStreamTests {

    private func makeStores() throws -> (LibraryStore, SyncStore, AudiobookDatabase) {
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

        return (LibraryStore(database: db), SyncStore(database: db), db)
    }

    /// Built from the same JSON shape the store tests use, which is the shape
    /// the decoders were written against — a fixture missing `key` or a part id
    /// fails to decode and the test reads as a database problem.
    private func cacheBook(_ library: LibraryStore, ratingKey: String) throws {
        let bookJSON = """
        {"ratingKey":"\(ratingKey)","title":"Book \(ratingKey)","parentTitle":"An Author",
         "titleSort":"Book \(ratingKey)","year":2008,"addedAt":1700000000}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(bookJSON.utf8))

        let trackJSON = """
        {"ratingKey":"t\(ratingKey)","key":"/library/metadata/t\(ratingKey)","title":"Part 1",
         "index":1,"duration":600000,
         "Media":[{"Part":[{"id":"p\(ratingKey)","key":"/library/parts/p\(ratingKey)/1700000000/f.mp3",
         "updatedAt":1700000000}]}]}
        """
        let track = try JSONDecoder().decode(PlexTrack.self, from: Data(trackJSON.utf8))

        try library.cache(book: book, tracks: [track], chapters: [], sectionID: "srv:2")
    }

    /// Collects what the stream delivers, off to one side.
    ///
    /// An `inout` iterator cannot be captured by an escaping closure, so racing
    /// `next()` against a timeout does not compile. A task consuming the stream
    /// into an actor does, and it also matches how the app uses it: a `for await`
    /// loop that runs for as long as the screen is up.
    private actor Emissions {
        private var values: [[BookRecord]] = []

        func append(_ value: [BookRecord]) { values.append(value) }
        var count: Int { values.count }
        var all: [[BookRecord]] { values }
    }

    /// Waits for a number of deliveries, or gives up.
    ///
    /// Bounded, because a stream that never delivers would otherwise hang the
    /// whole suite with no indication of which test is stuck — the same silence
    /// this mechanism exists to remove, reproduced in the tests.
    private func waitFor(
        _ emissions: Emissions,
        atLeast wanted: Int,
        seconds: Double = 5
    ) async throws -> [[BookRecord]] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await emissions.count >= wanted { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await emissions.all
    }

    /// Starts following the list, and hands back the collector.
    private func follow(_ library: LibraryStore) -> (Emissions, Task<Void, Never>) {
        let emissions = Emissions()
        let task = Task {
            do {
                for try await books in library.continueListeningStream() {
                    await emissions.append(books)
                }
            } catch {
                // Cancellation, at the end of a test.
            }
        }
        return (emissions, task)
    }

    /// The first delivery, which is what the screen shows on appearing.
    @Test("The stream delivers the current list straight away")
    func deliversInitialList() async throws {
        let (library, sync, _) = try makeStores()
        try cacheBook(library, ratingKey: "900")
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)

        let (emissions, task) = follow(library)
        defer { task.cancel() }

        let delivered = try await waitFor(emissions, atLeast: 1)
        #expect(delivered.first?.map(\.ratingKey) == ["900"])
    }

    /// The claim that made this worth doing: the stream and the query are the
    /// same question, so a screen using one cannot disagree with a screen using
    /// the other.
    @Test("The stream agrees with the one-shot query")
    func agreesWithQuery() async throws {
        let (library, sync, _) = try makeStores()
        try cacheBook(library, ratingKey: "900")
        try cacheBook(library, ratingKey: "901")
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)
        try sync.recordPosition(bookRatingKey: "901", absoluteMs: 60_000)

        let (emissions, task) = follow(library)
        defer { task.cancel() }

        let delivered = try await waitFor(emissions, atLeast: 1)
        let queried = try library.continueListening()
        #expect(delivered.first?.map(\.ratingKey) == queried.map(\.ratingKey))
    }

    /// The whole point: a write anywhere reaches the screen without anybody
    /// telling it to.
    @Test("A position written afterwards is delivered without being announced")
    func deliversOnWrite() async throws {
        let (library, sync, _) = try makeStores()
        try cacheBook(library, ratingKey: "900")
        try cacheBook(library, ratingKey: "901")
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)

        let (emissions, task) = follow(library)
        defer { task.cancel() }
        _ = try await waitFor(emissions, atLeast: 1)

        // Nothing signals and nothing bumps a counter. This is the write a
        // device makes when a book is paused, and previously the screen saw it
        // only because a call site remembered to say so.
        try sync.recordPosition(bookRatingKey: "901", absoluteMs: 30_000)

        let delivered = try await waitFor(emissions, atLeast: 2)
        #expect(delivered.last?.contains { $0.ratingKey == "901" } == true)
    }

    /// Finishing removes it, which is how a book finished on another device
    /// leaves the list here.
    @Test("Finishing a book removes it from the stream")
    func finishedLeaves() async throws {
        let (library, sync, _) = try makeStores()
        try cacheBook(library, ratingKey: "900")
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 120_000)

        let (emissions, task) = follow(library)
        defer { task.cancel() }
        _ = try await waitFor(emissions, atLeast: 1)

        try sync.markFinished(bookRatingKey: "900")

        let delivered = try await waitFor(emissions, atLeast: 2)
        #expect(delivered.last?.isEmpty == true)
    }
}
