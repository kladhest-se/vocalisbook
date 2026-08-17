import Foundation
import Testing
import PlexKit
@testable import Audiobooks

/// Offline mode promises the library contains only what will play.
///
/// A promise worth testing rather than eyeballing: the failure is a book that
/// appears on a plane, opens, and stops at the chapter that was never fetched —
/// which reads as the download having been lost.
@Suite("Offline library")
struct OfflineLibraryTests {

    private func seed() throws -> (LibraryStore, DownloadStore, AudiobookDatabase) {
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

        // Three books by two authors, each of two parts.
        let books: [(key: String, title: String, author: String)] = [
            ("900", "Downloaded", "Pratchett"),
            ("901", "Half downloaded", "Pratchett"),
            ("902", "Not downloaded", "Gaiman"),
        ]
        for entry in books {
            let book = try JSONDecoder().decode(PlexBook.self, from: Data("""
            {"ratingKey":"\(entry.key)","title":"\(entry.title)","parentTitle":"\(entry.author)",
             "addedAt":1700000000}
            """.utf8))
            let tracks = try (0..<2).map { index in
                try JSONDecoder().decode(PlexTrack.self, from: Data("""
                {"ratingKey":"t\(entry.key)-\(index)","key":"/library/metadata/t\(entry.key)-\(index)",
                 "title":"Part \(index + 1)","index":\(index + 1),"duration":600000,
                 "Media":[{"Part":[{"id":"p\(entry.key)-\(index)","key":"/p\(entry.key)-\(index)","updatedAt":1}]}]}
                """.utf8))
            }
            try library.cache(book: book, tracks: tracks, chapters: [], sectionID: "srv:2")
        }

        let downloads = DownloadStore(database: db)
        // Hoisted out of the macro for the reason StoreTests explains: a
        // throwing call inside one is reported against the expansion. The
        // check in contract.sh only looks for `#expect`, so this one would
        // have gone through — the convention is worth keeping anyway.
        var timelines: [CachedTimeline] = []
        for entry in books {
            let cached = try library.timeline(bookRatingKey: entry.key)
            timelines.append(try #require(cached))
        }

        // 900: both parts complete. 901: one of two — the case that matters.
        try downloads.enqueue(bookRatingKey: "900", segments: timelines[0].segments)
        for segment in timelines[0].segments {
            try downloads.markComplete(partCacheKey: segment.partCacheKey, relativePath: "\(segment.partCacheKey).m4b", bytes: 10)
        }
        try downloads.enqueue(bookRatingKey: "901", segments: timelines[1].segments)
        try downloads.markComplete(
            partCacheKey: timelines[1].segments[0].partCacheKey,
            relativePath: "one.m4b", bytes: 10
        )

        return (library, downloads, db)
    }

    /// The whole point: a partly downloaded book is not offline-playable.
    @Test("Only fully downloaded books are listed")
    func onlyCompleteBooks() throws {
        let (library, _, _) = try seed()

        let all = try library.books(sectionID: "srv:2")
        let offline = try library.books(sectionID: "srv:2", downloadedOnly: true)

        #expect(all.count == 3)
        #expect(offline.map(\.ratingKey) == ["900"])
    }

    @Test("Authors with nothing downloaded disappear")
    func authorsAreFiltered() throws {
        let (library, _, _) = try seed()

        let all = try library.authors(sectionID: "srv:2")
        let offline = try library.authors(sectionID: "srv:2", downloadedOnly: true)

        #expect(Set(all.map(\.name)) == ["Pratchett", "Gaiman"])
        // Pratchett survives on one book, not two.
        #expect(offline.map(\.name) == ["Pratchett"])
        #expect(offline.first?.bookCount == 1)
    }

    @Test("An author's books are filtered too")
    func authorBooksAreFiltered() throws {
        let (library, _, _) = try seed()

        let all = try library.books(byAuthor: "Pratchett", sectionID: "srv:2")
        let offline = try library.books(byAuthor: "Pratchett", sectionID: "srv:2", downloadedOnly: true)

        #expect(all.count == 2)
        #expect(offline.map(\.ratingKey) == ["900"])
    }

    @Test("Search cannot reach a book that is not on the device")
    func searchIsFiltered() throws {
        let (library, _, _) = try seed()

        let all = try library.search("downloaded")
        let offline = try library.search("downloaded", downloadedOnly: true)

        #expect(all.count == 3)
        #expect(offline.map(\.ratingKey) == ["900"])
    }

    @Test("Recently added is filtered")
    func recentlyAddedIsFiltered() throws {
        let (library, _, _) = try seed()

        let offline = try library.recentlyAdded(sectionID: "srv:2", downloadedOnly: true)
        #expect(offline.map(\.ratingKey) == ["900"])
    }

    /// Continue listening is where a missing book hurts most: it is the row
    /// somebody taps without looking.
    @Test("Continue listening is filtered")
    func continueListeningIsFiltered() throws {
        // The database is handed back rather than reached for through the
        // store, whose own reference is private — as it should be.
        let (library, _, db) = try seed()
        let sync = SyncStore(database: db)
        try sync.recordPosition(bookRatingKey: "900", absoluteMs: 1_000)
        try sync.recordPosition(bookRatingKey: "902", absoluteMs: 1_000)

        let all = try library.continueListening()
        let offline = try library.continueListening(downloadedOnly: true)

        #expect(all.count == 2)
        #expect(offline.map(\.ratingKey) == ["900"])
    }

    /// Off by default, so nothing above changes the ordinary path.
    @Test("The filter is opt-in")
    func filterIsOptIn() throws {
        let (library, _, _) = try seed()
        let books = try library.books(sectionID: "srv:2")
        #expect(books.count == 3)
    }
}
