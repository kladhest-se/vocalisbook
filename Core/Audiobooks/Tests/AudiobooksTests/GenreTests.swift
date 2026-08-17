import Foundation
import Testing
import PlexKit
@testable import Audiobooks

/// Genres, which a book has several of.
///
/// That is the whole reason they are a table rather than a column: a list in a
/// column cannot be grouped or counted without unpacking every row in the
/// library first.
@Suite("Genres")
struct GenreTests {

    /// The same store, and the database behind it.
    ///
    /// `LibraryStore.database` is private and should stay private — a test
    /// needing a `SyncStore` on the same database is not a reason to widen the
    /// type's surface.
    private func makeStoreAndDatabase() throws -> (LibraryStore, AudiobookDatabase) {
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
        return (LibraryStore(database: db), db)
    }

    private func makeStore() throws -> LibraryStore {
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
        return LibraryStore(database: db)
    }

    private func cache(
        _ store: LibraryStore,
        key: String,
        title: String,
        thumb: String? = "/t/\(UUID().uuidString)",
        genres: [String]
    ) throws {
        let tags = genres.map { #"{"tag":"\#($0)"}"# }.joined(separator: ",")
        let thumbField = thumb.map { #""thumb":"\#($0)","# } ?? ""
        let book = try JSONDecoder().decode(PlexBook.self, from: Data("""
        {"ratingKey":"\(key)","title":"\(title)","parentTitle":"Pratchett",
         \(thumbField)"Genre":[\(tags)]}
        """.utf8))
        let track = try JSONDecoder().decode(PlexTrack.self, from: Data("""
        {"ratingKey":"t\(key)","key":"/library/metadata/t\(key)","title":"Part 1",
         "index":1,"duration":600000,
         "Media":[{"Part":[{"id":"p\(key)","key":"/p\(key)","size":1}]}]}
        """.utf8))
        try store.cache(book: book, tracks: [track], chapters: [], sectionID: "srv:2")
    }

    // MARK: - Decoding

    /// Plex sends `"Genre": [{"tag": "Fantasy"}]` — objects, not strings.
    @Test("Genre tags decode from the objects Plex sends")
    func decodesTags() throws {
        let book = try JSONDecoder().decode(PlexBook.self, from: Data("""
        {"ratingKey":"900","title":"Guards! Guards!",
         "Genre":[{"tag":"Fantasy"},{"tag":"Humour"}]}
        """.utf8))

        #expect(book.genres == ["Fantasy", "Humour"])
    }

    /// The list endpoint omits tags entirely; only the detail endpoint carries
    /// them. A missing key is not an error.
    @Test("A book with no Genre key has no genres, and does not fail")
    func missingKeyIsEmpty() throws {
        let book = try JSONDecoder().decode(PlexBook.self, from: Data("""
        {"ratingKey":"900","title":"Guards! Guards!"}
        """.utf8))

        #expect(book.genres.isEmpty)
    }

    // MARK: - Storing

    @Test("A book appears under each of its genres")
    func bookAppearsUnderEach() throws {
        let store = try makeStore()
        try cache(store, key: "900", title: "Guards! Guards!", genres: ["Fantasy", "Humour"])

        let genres = try store.genres(sectionID: "srv:2")

        #expect(genres.map(\.name) == ["Fantasy", "Humour"])
        #expect(genres.allSatisfy { $0.bookCount == 1 })
    }

    @Test("Genres are counted across books and ordered by name")
    func countedAndOrdered() throws {
        let store = try makeStore()
        try cache(store, key: "900", title: "Guards! Guards!", genres: ["Humour", "Fantasy"])
        try cache(store, key: "901", title: "Small Gods", genres: ["Fantasy"])

        let genres = try store.genres(sectionID: "srv:2")

        #expect(genres.map(\.name) == ["Fantasy", "Humour"])
        #expect(genres.first?.bookCount == 2)
    }

    /// A refresh caches every book again. Without the delete, a genre would
    /// either collide on the primary key or accumulate a row per refresh.
    @Test("Re-caching a book does not duplicate its genres")
    func recachingReplaces() throws {
        let store = try makeStore()
        try cache(store, key: "900", title: "Guards! Guards!", genres: ["Fantasy"])
        try cache(store, key: "900", title: "Guards! Guards!", genres: ["Fantasy"])

        let genres = try store.genres(sectionID: "srv:2")
        #expect(genres.count == 1)
        #expect(genres.first?.bookCount == 1)
    }

    /// A genre taken off a book on the server should go here too — which an
    /// upsert alone would never notice.
    @Test("A genre removed on the server is removed here")
    func removedGenreDisappears() throws {
        let store = try makeStore()
        try cache(store, key: "900", title: "Guards! Guards!", genres: ["Fantasy", "Humour"])
        try cache(store, key: "900", title: "Guards! Guards!", genres: ["Fantasy"])

        let genres = try store.genres(sectionID: "srv:2")
        #expect(genres.map(\.name) == ["Fantasy"])
    }

    /// The list endpoint sends no tags at all, and a refresh from it must not be
    /// read as "this book has no genres any more".
    @Test("A response with no tags leaves the genres alone")
    func noTagsDoesNotEmptyTheTable() throws {
        let store = try makeStore()
        try cache(store, key: "900", title: "Guards! Guards!", genres: ["Fantasy"])
        try cache(store, key: "900", title: "Guards! Guards!", genres: [])

        let genres = try store.genres(sectionID: "srv:2")
        #expect(genres.map(\.name) == ["Fantasy"])
    }

    // MARK: - Browsing

    @Test("The books in a genre come back in title order")
    func booksInGenre() throws {
        let store = try makeStore()
        try cache(store, key: "900", title: "Zebra", genres: ["Fantasy"])
        try cache(store, key: "901", title: "Apple", genres: ["Fantasy"])
        try cache(store, key: "902", title: "Elsewhere", genres: ["Crime"])

        let books = try store.books(inGenre: "Fantasy", sectionID: "srv:2")
        #expect(books.map(\.title) == ["Apple", "Zebra"])
    }

    /// A book with no artwork must not take a collage slot and leave a hole.
    @Test("Covers skip books that have none")
    func coversSkipBlanks() throws {
        let store = try makeStore()
        try cache(store, key: "900", title: "Apple", thumb: nil, genres: ["Fantasy"])
        try cache(store, key: "901", title: "Banana", thumb: "/t/b", genres: ["Fantasy"])

        let genres = try store.genres(sectionID: "srv:2")
        #expect(genres.first?.covers == ["/t/b"])
        #expect(genres.first?.bookCount == 2)
    }

    @Test("A library with no matched books has no genres, not an error")
    func noGenresIsEmpty() throws {
        let store = try makeStore()
        try cache(store, key: "900", title: "Unmatched", genres: [])

        let genres = try store.genres(sectionID: "srv:2")
        #expect(genres.isEmpty)
    }
    /// Narrators, co-authors and series, cached from the tags SpokenMeta writes.
    @Test("Caching a book stores its narrators, authors and series")
    func storesCredits() throws {
        let library = try makeStore()

        let json = """
        {"ratingKey":"900","title":"Wyrd Sisters","parentTitle":"Terry Pratchett",
         "Style":[{"tag":"Stephen Briggs"}],
         "Mood":[{"tag":"Terry Pratchett"},{"tag":"Series: Discworld"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")

        let credits = try library.credits(bookRatingKey: "900")
        #expect(credits.narrators == ["Stephen Briggs"])
        #expect(credits.authors == ["Terry Pratchett"])
        #expect(credits.series == ["Discworld"])
    }

    /// The same rule genres already follow: an empty list means the endpoint was
    /// not asked, not that the book has none. Emptying the table on every
    /// library refresh would lose what the detail endpoint had supplied.
    @Test("A response without tags leaves stored credits alone")
    func untaggedResponseKeepsCredits() throws {
        let library = try makeStore()

        let tagged = """
        {"ratingKey":"900","title":"Wyrd Sisters",
         "Style":[{"tag":"Stephen Briggs"}],"Mood":[{"tag":"Series: Discworld"}]}
        """
        try library.cacheBookList(
            [try JSONDecoder().decode(PlexBook.self, from: Data(tagged.utf8))],
            sectionID: "srv:2"
        )

        let bare = """
        {"ratingKey":"900","title":"Wyrd Sisters"}
        """
        try library.cacheBookList(
            [try JSONDecoder().decode(PlexBook.self, from: Data(bare.utf8))],
            sectionID: "srv:2"
        )

        let credits = try library.credits(bookRatingKey: "900")
        #expect(credits.narrators == ["Stephen Briggs"])
        #expect(credits.series == ["Discworld"])
    }

    /// Language and edition are stored on the book and read back together.
    @Test("Caching stores language, edition and the durable identity")
    func storesEditionAndIdentity() throws {
        let library = try makeStore()

        let json = """
        {"ratingKey":"900","title":"Project Hail Mary",
         "guid":"com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en",
         "Mood":[{"tag":"Language: English"},{"tag":"Edition: Unabridged"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")

        let credits = try library.credits(bookRatingKey: "900")
        #expect(credits.language == "English")
        #expect(credits.edition == "Unabridged")
        #expect(credits.editionLine == "Unabridged · English")

        let stored = try library.book(ratingKey: "900")
        #expect(stored?.identityKey == "spokenmeta:audible:us:B08G9PRS1K")
    }

    /// A book no agent matched gets the per-server fallback, built from the
    /// section id's server component.
    @Test("An unmatched book gets a server-namespaced identity")
    func unmatchedBookIdentity() throws {
        let library = try makeStore()

        let json = """
        {"ratingKey":"900","title":"Road Kill","guid":"local://900"}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")

        let stored = try library.book(ratingKey: "900")
        #expect(stored?.identityKey == "plex:srv:900")
    }

    /// Neither known means no line at all, rather than a stray separator.
    @Test("No language or edition means no line")
    func noEditionLine() throws {
        let library = try makeStore()

        let json = """
        {"ratingKey":"900","title":"A Book"}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")

        let credits = try library.credits(bookRatingKey: "900")
        #expect(credits.editionLine == nil)
    }

    // MARK: - Series

    private func cacheSeriesBooks(_ library: LibraryStore) throws {
        let books = [
            ("1", "Discworld", "10"),
            ("2", "Discworld", "2"),
            ("3", "Discworld", "3.5"),
            ("4", "Discworld", "Special"),
        ]
        let decoded = try books.map { key, series, position -> PlexBook in
            let json = """
            {"ratingKey":"\(key)","title":"Book \(key)",
             "Mood":[{"tag":"Series: \(series)"},
                     {"tag":"Sequence: \(series) #\(position)"}]}
            """
            return try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        }
        try library.cacheBookList(decoded, sectionID: "srv:2")
    }

    @Test("A series is listed with its book count")
    func seriesListed() throws {
        let library = try makeStore()
        try cacheSeriesBooks(library)

        let series = try library.series(sectionID: "srv:2")
        #expect(series.count == 1)
        #expect(series.first?.name == "Discworld")
        #expect(series.first?.bookCount == 4)
    }

    /// Numerically, and with the decimal in its right place. As text `10` sorts
    /// before `2`, which is the whole reason this is ordered in Swift.
    @Test("Books come back in stated order")
    func seriesOrder() throws {
        let library = try makeStore()
        try cacheSeriesBooks(library)

        let entries = try library.books(inSeries: "Discworld")
        #expect(entries.map(\.book.ratingKey) == ["2", "3", "1", "4"])
    }

    /// A position nothing can order goes last rather than being treated as zero
    /// and leading the series.
    @Test("An unorderable position sorts last, and is still shown")
    func unorderablePositionLast() throws {
        let library = try makeStore()
        try cacheSeriesBooks(library)

        let entries = try library.books(inSeries: "Discworld")
        #expect(entries.last?.book.ratingKey == "4")
        #expect(entries.last?.position == "Special")
    }

    // MARK: - Standing within a series

    @Test("A book knows its place among the ones held here")
    func standingCountsWhatIsHeld() throws {
        let library = try makeStore()
        try cacheSeriesBooks(library)

        let stored = try library.standing(ofBook: "2")
        let standing = try #require(stored)
        #expect(standing.series == "Discworld")
        #expect(standing.position == "2")
        #expect(standing.heldInLibrary == 4)
    }

    /// The count is of what is indexed here, so it moves when the library does.
    /// That is the whole reason the screens say "in your library".
    @Test("The total is a count of this library, not of the series")
    func totalFollowsTheLibrary() throws {
        let library = try makeStore()
        try cacheSeriesBooks(library)

        let json = """
        {"ratingKey":"5","title":"Book 5",
         "Mood":[{"tag":"Series: Discworld"},{"tag":"Sequence: Discworld #12"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")

        let stored = try library.standing(ofBook: "2")
        let standing = try #require(stored)
        #expect(standing.heldInLibrary == 5)
    }

    /// "Book 1 of 1" describes a gap in the library rather than a fact about the
    /// series, so nothing is said.
    @Test("A series with one book held says nothing")
    func loneBookHasNoStanding() throws {
        let library = try makeStore()

        let json = """
        {"ratingKey":"900","title":"Alone",
         "Mood":[{"tag":"Series: Solitary"},{"tag":"Sequence: Solitary #1"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")

        let standing = try library.standing(ofBook: "900")
        #expect(standing == nil)
    }

    /// A book in a series the agent did not place has no position to show.
    @Test("A book with no stated position has no standing")
    func noPositionNoStanding() throws {
        let library = try makeStore()

        let books = try ["10", "11"].map { key -> PlexBook in
            let json = """
            {"ratingKey":"\(key)","title":"Book \(key)",
             "Mood":[{"tag":"Series: Unplaced"}]}
            """
            return try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        }
        try library.cacheBookList(books, sectionID: "srv:2")

        let standing = try library.standing(ofBook: "10")
        #expect(standing == nil)
    }

    /// The other end of Continue listening.
    @Test("Finished books are listed, most recent first")
    func recentlyFinishedOrder() throws {
        let (library, db) = try makeStoreAndDatabase()
        try cacheSeriesBooks(library)

        let sync = SyncStore(database: db)
        try sync.markFinished(bookRatingKey: "1", at: Date(timeIntervalSince1970: 1_000))
        try sync.markFinished(bookRatingKey: "2", at: Date(timeIntervalSince1970: 2_000))

        let finished = try library.recentlyFinished()
        #expect(finished.map(\.ratingKey) == ["2", "1"])
    }

    /// Pressing the tick twice takes a book out of here as well as putting it
    /// back to the beginning — the same `finished_at` decides both.
    @Test("Unfinishing removes a book from the list")
    func unfinishingRemoves() throws {
        let (library, db) = try makeStoreAndDatabase()
        try cacheSeriesBooks(library)

        let sync = SyncStore(database: db)
        try sync.markFinished(bookRatingKey: "1")

        let before = try library.recentlyFinished()
        #expect(before.map(\.ratingKey) == ["1"])

        try sync.resetProgress(bookRatingKey: "1")

        let after = try library.recentlyFinished()
        #expect(after.isEmpty)
    }

    /// The album artist is whatever the files were tagged with, and for
    /// audiobooks that is very often the narrator — a library will happily show
    /// a biography credited to the person who read it.
    @Test("The agent's author wins over the album artist")
    func agentAuthorPreferred() throws {
        let library = try makeStore()

        let json = """
        {"ratingKey":"900","title":"Elon Musk",
         "parentTitle":"Jeremy Bobb",
         "Mood":[{"tag":"Walter Isaacson"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")

        let stored = try library.book(ratingKey: "900")
        #expect(stored?.author == "Walter Isaacson")
    }

    /// A library nothing has matched has no Mood authors, and the album artist
    /// is all there is.
    @Test("An unmatched book keeps the album artist")
    func unmatchedKeepsArtist() throws {
        let library = try makeStore()

        let json = """
        {"ratingKey":"901","title":"Some Book","parentTitle":"A Tagger's Guess"}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        try library.cacheBookList([book], sectionID: "srv:2")

        let stored = try library.book(ratingKey: "901")
        #expect(stored?.author == "A Tagger's Guess")
    }

}
