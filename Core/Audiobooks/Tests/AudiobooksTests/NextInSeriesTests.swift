import Foundation
import Testing
import PlexKit
@testable import Audiobooks

/// Finishing a book used to do nothing: position marked, session closed, and no
/// hint that book thirty-three exists. The order was already in the store —
/// Plex collections carry their own, which for a series is reading order.
@Suite("Next in series")
struct NextInSeriesTests {

    private func seed(
        books: [String],
        collections: [(key: String, title: String, members: [String])]
    ) throws -> LibraryStore {
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

        let store = LibraryStore(database: db)

        for key in books {
            let book = try JSONDecoder().decode(PlexBook.self, from: Data("""
            {"ratingKey":"\(key)","title":"Book \(key)","parentTitle":"Pratchett"}
            """.utf8))
            let track = try JSONDecoder().decode(PlexTrack.self, from: Data("""
            {"ratingKey":"t\(key)","key":"/library/metadata/t\(key)","title":"Part 1",
             "index":1,"duration":600000,
             "Media":[{"Part":[{"id":"p\(key)","key":"/p\(key)","updatedAt":1}]}]}
            """.utf8))
            try store.cache(book: book, tracks: [track], chapters: [], sectionID: "srv:2")
        }

        let entries = try collections.map { entry in
            let collection = try JSONDecoder().decode(PlexCollection.self, from: Data("""
            {"ratingKey":"\(entry.key)","title":"\(entry.title)"}
            """.utf8))
            return (collection: collection, bookRatingKeys: entry.members)
        }
        try store.cacheCollections(entries, sectionID: "srv:2")

        return store
    }

    @Test("The next book in the collection's own order")
    func nextByPosition() throws {
        let store = try seed(
            books: ["900", "901", "902"],
            collections: [(key: "c1", title: "Discworld", members: ["900", "901", "902"])]
        )

        let next = try store.nextInSeries(after: "900")
        #expect(next?.book.ratingKey == "901")
        #expect(next?.seriesTitle == "Discworld")
    }

    /// Position, not title order — a series is not alphabetical and the whole
    /// point of using the collection is that Plex already knows the order.
    @Test("Order comes from the collection, not the titles")
    func orderIsPlexs() throws {
        let store = try seed(
            books: ["900", "901", "902"],
            collections: [(key: "c1", title: "Discworld", members: ["902", "900", "901"])]
        )

        let next = try store.nextInSeries(after: "902")
        #expect(next?.book.ratingKey == "900")
    }

    @Test("The last book in a series has no next")
    func lastBook() throws {
        let store = try seed(
            books: ["900", "901"],
            collections: [(key: "c1", title: "Discworld", members: ["900", "901"])]
        )

        let next = try store.nextInSeries(after: "901")
        #expect(next == nil)
    }

    @Test("A book in no collection has no next")
    func noCollection() throws {
        let store = try seed(books: ["900"], collections: [])
        let next = try store.nextInSeries(after: "900")
        #expect(next == nil)
    }

    /// A book can be in several collections and nothing in Plex says which one
    /// is "the series". The answer has to be arbitrary; it must not be unstable.
    @Test("A book in two collections gives the same answer every time")
    func stableAcrossCollections() throws {
        let store = try seed(
            books: ["900", "901", "902"],
            collections: [
                (key: "c2", title: "Witches", members: ["900", "902"]),
                (key: "c1", title: "Discworld", members: ["900", "901"]),
            ]
        )

        let first = try store.nextInSeries(after: "900")
        let second = try store.nextInSeries(after: "900")

        // Ordered by collection title, so Discworld wins over Witches.
        #expect(first?.seriesTitle == "Discworld")
        #expect(first?.book.ratingKey == "901")
        #expect(first == second)
    }

    /// The collection this book is last in must not shadow one where it is not.
    @Test("A collection with no successor falls through to one that has")
    func fallsThroughToACollectionWithMore() throws {
        let store = try seed(
            books: ["900", "901"],
            collections: [
                (key: "c1", title: "Anthologies", members: ["900"]),
                (key: "c2", title: "Discworld", members: ["900", "901"]),
            ]
        )

        let next = try store.nextInSeries(after: "900")
        #expect(next?.book.ratingKey == "901")
        #expect(next?.seriesTitle == "Discworld")
    }
    // MARK: - The agent's own positions

    /// Books carrying `Sequence:` tags, cached the way a refresh would.
    private func seedTagged(_ books: [(key: String, series: String, position: String)]) throws -> LibraryStore {
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
        let decoded = try books.map { book -> PlexBook in
            let json = """
            {"ratingKey":"\(book.key)","title":"Book \(book.key)",
             "Mood":[{"tag":"Series: \(book.series)"},
                     {"tag":"Sequence: \(book.series) #\(book.position)"}]}
            """
            return try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        }
        try library.cacheBookList(decoded, sectionID: "srv:2")
        return library
    }

    @Test("The next stated position wins")
    func nextStatedPosition() throws {
        let library = try seedTagged([
            (key: "1", series: "Discworld", position: "5"),
            (key: "2", series: "Discworld", position: "6"),
            (key: "3", series: "Discworld", position: "7"),
        ])

        let next = try library.nextInSeries(after: "1")
        #expect(next?.book.ratingKey == "2")
        #expect(next?.seriesTitle == "Discworld")
        #expect(next?.source == .seriesTag(position: "6"))
    }

    /// The reason positions are ordered in Swift rather than SQL: as text, `10`
    /// sorts before `2`.
    @Test("Positions order numerically, not lexically")
    func numericOrdering() throws {
        let library = try seedTagged([
            (key: "1", series: "Discworld", position: "2"),
            (key: "2", series: "Discworld", position: "10"),
            (key: "3", series: "Discworld", position: "3"),
        ])

        let next = try library.nextInSeries(after: "1")
        #expect(next?.book.ratingKey == "3")
    }

    /// A novella between two books. Parsing positions as integers would drop it.
    @Test("A decimal position is a real position")
    func decimalPosition() throws {
        let library = try seedTagged([
            (key: "1", series: "Some Series", position: "3"),
            (key: "2", series: "Some Series", position: "3.5"),
            (key: "3", series: "Some Series", position: "4"),
        ])

        let next = try library.nextInSeries(after: "1")
        #expect(next?.book.ratingKey == "2")
        #expect(next?.source == .seriesTag(position: "3.5"))
    }

    /// The last book in a series has no successor, rather than wrapping around.
    @Test("The last book has no next")
    func lastBookHasNoNext() throws {
        let library = try seedTagged([
            (key: "1", series: "Discworld", position: "5"),
            (key: "2", series: "Discworld", position: "6"),
        ])

        let next = try library.nextInSeries(after: "2")
        #expect(next == nil)
    }

    /// A position the contract allows but nothing can order.
    @Test("An unparseable position is not offered as next")
    func unparseablePosition() throws {
        let library = try seedTagged([
            (key: "1", series: "Discworld", position: "5"),
            (key: "2", series: "Discworld", position: "Special"),
        ])

        let next = try library.nextInSeries(after: "1")
        #expect(next == nil)
    }

}
