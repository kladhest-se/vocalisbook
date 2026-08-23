import Foundation
import Testing
import PlexKit
@testable import Audiobooks

/// The authors grid on the television is built from this one query.
///
/// It used to be a `GROUP BY` returning a name and a count, which is all a list
/// of names needs. A grid of cards needs art as well, and gathering it wrongly
/// is invisible in a test that only checks the counts — a collage silently short
/// of covers reads as a failed download rather than a bad query.
@Suite("Authors")
struct AuthorsTests {

    /// Seeds one book per entry, crediting `author` both ways.
    ///
    /// `parentTitle` *and* a bare `Mood`, because those are two different
    /// claims: the first is whatever the files were tagged with, the second is
    /// the metadata agent naming a writer. Only the second builds this screen.
    /// Passing an author here means "the agent credited this person", which is
    /// what every test below is actually about; a book with an album artist and
    /// no Mood is a different case, and `unmatchedBooksHaveNoWriter` covers it.
    private func seed(books: [(title: String, author: String?, thumb: String?)]) throws -> LibraryStore {
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
        for (index, entry) in books.enumerated() {
            var fields = """
            "ratingKey":"b\(index)","title":"\(entry.title)"
            """
            if let author = entry.author {
                fields += ",\"parentTitle\":\"\(author)\""
                fields += ",\"Mood\":[{\"tag\":\"\(author)\"}]"
            }
            if let thumb = entry.thumb { fields += ",\"thumb\":\"\(thumb)\"" }

            let book = try JSONDecoder().decode(PlexBook.self, from: Data("{\(fields)}".utf8))
            let track = try JSONDecoder().decode(PlexTrack.self, from: Data("""
            {"ratingKey":"t\(index)","key":"/library/metadata/t\(index)","title":"Part 1",
             "index":1,"duration":600000,
             "Media":[{"Part":[{"id":"p\(index)","key":"/p\(index)","updatedAt":1}]}]}
            """.utf8))
            try store.cache(book: book, tracks: [track], chapters: [], sectionID: "srv:2")
        }
        return store
    }

    @Test("Authors are grouped, counted and ordered case-insensitively")
    func groupingAndOrder() throws {
        let store = try seed(books: [
            (title: "Beta", author: "de Beauvoir", thumb: "/a"),
            (title: "Alpha", author: "Adams", thumb: "/b"),
            (title: "Gamma", author: "adams", thumb: "/c"),
        ])

        let authors = try store.authors(sectionID: "srv:2")

        // "Adams" and "adams" are different authors — the collation orders them
        // together but does not merge them, and merging would be a guess about
        // somebody's library rather than a fact about it. Their order relative
        // to each other is settled by the secondary sort on title, not left to
        // whatever SQLite returns for two keys that compare equal.
        #expect(authors.map(\.name) == ["Adams", "adams", "de Beauvoir"])
        #expect(authors.allSatisfy { $0.bookCount == 1 })
    }

    @Test("Books with no credited writer are left out entirely")
    func missingAuthors() throws {
        let store = try seed(books: [
            (title: "Anonymous", author: nil, thumb: "/a"),
            (title: "Known", author: "Pratchett", thumb: "/b"),
        ])

        let authors = try store.authors(sectionID: "srv:2")
        #expect(authors.map(\.name) == ["Pratchett"])
    }

    @Test("Covers are collected up to the limit, in title order")
    func coversAreCollected() throws {
        let store = try seed(books: [
            (title: "D", author: "Pratchett", thumb: "/d"),
            (title: "A", author: "Pratchett", thumb: "/a"),
            (title: "C", author: "Pratchett", thumb: "/c"),
            (title: "B", author: "Pratchett", thumb: "/b"),
            (title: "E", author: "Pratchett", thumb: "/e"),
        ])

        let authors = try store.authors(sectionID: "srv:2")
        let pratchett = try #require(authors.first)

        #expect(pratchett.bookCount == 5)
        // Four, not five, and the four whose titles sort first.
        #expect(pratchett.covers == ["/a", "/b", "/c", "/d"])
    }

    /// The case that produces a hole in the collage.
    @Test("A book with no artwork does not take a collage slot")
    func artworklessBooksSkipped() throws {
        let store = try seed(books: [
            (title: "A", author: "Pratchett", thumb: nil),
            (title: "B", author: "Pratchett", thumb: ""),
            (title: "C", author: "Pratchett", thumb: "/c"),
            (title: "D", author: "Pratchett", thumb: "/d"),
        ])

        let authors = try store.authors(sectionID: "srv:2")
        let pratchett = try #require(authors.first)

        // All four books are counted; only the two with art are shown.
        #expect(pratchett.bookCount == 4)
        #expect(pratchett.covers == ["/c", "/d"])
    }

    @Test("The cover limit is configurable")
    func coverLimit() throws {
        let store = try seed(books: [
            (title: "A", author: "Pratchett", thumb: "/a"),
            (title: "B", author: "Pratchett", thumb: "/b"),
            (title: "C", author: "Pratchett", thumb: "/c"),
        ])

        let authors = try store.authors(sectionID: "srv:2", coversPerAuthor: 2)
        #expect(authors.first?.covers == ["/a", "/b"])
    }

    /// Drilling into an author is the whole point of the screen.
    @Test("Books by one author come back in title order")
    func booksByAuthor() throws {
        let store = try seed(books: [
            (title: "Wyrd Sisters", author: "Pratchett", thumb: "/w"),
            (title: "Mort", author: "Pratchett", thumb: "/m"),
            (title: "Dune", author: "Herbert", thumb: "/d"),
        ])

        let books = try store.books(byAuthor: "Pratchett", sectionID: "srv:2")
        #expect(books.map(\.title) == ["Mort", "Wyrd Sisters"])
    }
    /// A store holding books with Mood authors.
    ///
    /// `seed` above takes one author per book and no tags, which cannot express
    /// the case these tests are about. Extending it would have meant every
    /// existing caller passing an empty list for something they do not care
    /// about.
    private func seedTagged(_ books: [(key: String, artist: String?, moods: [String])]) throws -> LibraryStore {
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
        let decoded = try books.map { book -> PlexBook in
            var fields = "\"ratingKey\":\"\(book.key)\",\"title\":\"Book \(book.key)\""
            if let artist = book.artist { fields += ",\"parentTitle\":\"\(artist)\"" }
            if !book.moods.isEmpty {
                let tags = book.moods.map { "{\"tag\":\"\($0)\"}" }.joined(separator: ",")
                fields += ",\"Mood\":[\(tags)]"
            }
            return try JSONDecoder().decode(PlexBook.self, from: Data("{\(fields)}".utf8))
        }
        try store.cacheBookList(decoded, sectionID: "srv:2")
        return store
    }

    /// A co-written book belongs on both writers' pages.
    ///
    /// Plex's album artist is one name — whoever the scanner picked — and the
    /// metadata agent credits every author as a Mood. Reading only the first
    /// meant a book by two writers was missing from one of them entirely.
    @Test("A co-author is an author")
    func coAuthorsAreListed() throws {
        let library = try seedTagged([
            (key: "900", artist: "Terry Pratchett", moods: ["Terry Pratchett", "Neil Gaiman"]),
        ])

        let authors = try library.authors(sectionID: "srv:2")
        #expect(authors.contains { $0.name == "Terry Pratchett" })
        #expect(authors.contains { $0.name == "Neil Gaiman" })

        let gaiman = try library.books(byAuthor: "Neil Gaiman", sectionID: "srv:2")
        #expect(gaiman.map(\.ratingKey) == ["900"])
    }

    /// A book credited once is counted once.
    ///
    /// This used to guard a `UNION` between the album artist and the Mood
    /// authors, where a book normally satisfied both sides and counting it
    /// twice would have said a writer has forty books when they have twenty.
    /// The union is gone; the assertion is kept because the failure it catches
    /// is not — duplicate rows in `book_author` would produce it just as well.
    @Test("A book credited once is counted once")
    func noDoubleCounting() throws {
        let library = try seedTagged([
            (key: "900", artist: "Terry Pratchett", moods: ["Terry Pratchett"]),
        ])

        let authors = try library.authors(sectionID: "srv:2")
        let pratchett = try #require(authors.first { $0.name == "Terry Pratchett" })
        #expect(pratchett.bookCount == 1)

        let books = try library.books(byAuthor: "Terry Pratchett", sectionID: "srv:2")
        #expect(books.count == 1)
    }

    /// The reported bug, in the shape it was reported in.
    ///
    /// A library showed two Terry Pratchetts: one from the Mood tags, and one
    /// reading "Terry Pratchett, Stephen Baxter" because that is what the files
    /// carried as `ALBUMARTIST` and Plex made an artist of it verbatim. Nothing
    /// normalises names, so the union treated the joined string as a third
    /// person. Dropping the album artist is what fixes it — splitting on the
    /// comma would not, since `Last, First` and `Jr.` both contain one.
    @Test("The album artist is never a writer")
    func albumArtistIsNotAWriter() throws {
        let library = try seedTagged([
            (
                key: "900",
                artist: "Terry Pratchett, Stephen Baxter",
                moods: ["Terry Pratchett", "Stephen Baxter"]
            ),
        ])

        let authors = try library.authors(sectionID: "srv:2")
        #expect(authors.map(\.name) == ["Stephen Baxter", "Terry Pratchett"])

        // Hoisted out of the macro: a throwing call inside one is reported
        // against the expansion rather than the line.
        let joined = try library.books(
            byAuthor: "Terry Pratchett, Stephen Baxter", sectionID: "srv:2"
        )
        #expect(joined.isEmpty)

        let pratchett = try library.books(byAuthor: "Terry Pratchett", sectionID: "srv:2")
        #expect(pratchett.map(\.ratingKey) == ["900"])
    }

    /// The cost of the decision above, stated as a test rather than left to be
    /// discovered.
    ///
    /// A book no agent has matched carries no Mood at all, so it has no writer
    /// and appears under nobody. The album artist it does have is not consulted,
    /// on the grounds that in an audiobook library that field is as likely to
    /// name the narrator as the writer.
    @Test("A book the agent has not matched has no writer")
    func unmatchedBooksHaveNoWriter() throws {
        let library = try seedTagged([
            (key: "900", artist: "Jeremy Bobb", moods: []),
        ])

        let authors = try library.authors(sectionID: "srv:2")
        #expect(authors.isEmpty)

        let bobb = try library.books(byAuthor: "Jeremy Bobb", sectionID: "srv:2")
        #expect(bobb.isEmpty)
    }

}
