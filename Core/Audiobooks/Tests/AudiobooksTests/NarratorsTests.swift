import Foundation
import Testing
import PlexKit
@testable import Audiobooks

/// Narrators are simpler than authors underneath — a single source,
/// `book_narrator` from `Style` values, with no union of two ways of
/// crediting someone. These cover the same shape of behaviour
/// `AuthorsTests` does, scaled to that simpler model.
@Suite("Narrators")
struct NarratorsTests {

    private func seed(books: [(title: String, narrators: [String], thumb: String?)]) throws -> LibraryStore {
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
            if let thumb = entry.thumb { fields += ",\"thumb\":\"\(thumb)\"" }
            if !entry.narrators.isEmpty {
                let styles = entry.narrators.map { #"{"tag":"\#($0)"}"# }.joined(separator: ",")
                fields += ",\"Style\":[\(styles)]"
            }

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

    @Test("Narrators are grouped, counted and ordered case-insensitively")
    func groupingAndOrder() throws {
        let store = try seed(books: [
            ("Wyrd Sisters", ["Celia Imrie"], nil),
            ("Equal Rites", ["celia imrie"], nil),
            ("Mort", ["Andy Serkis"], nil),
        ])

        let narrators = try store.narrators(sectionID: "srv:2")

        // Ordered case-insensitively, and *not* merged — which is what this
        // test's own name says and what its assertions used to contradict.
        //
        // `AuthorsTests.groupingAndOrder` is the same test with a different
        // noun and states the reasoning: the collation orders "Adams" and
        // "adams" together but does not merge them, because merging would be a
        // guess about somebody's library rather than a fact about it. Nothing
        // in `narrators` ever merged either; the assertion here demanded a
        // behaviour no version of that query has had.
        //
        // The principled way to get the outcome it wanted is the canonical
        // key, not the collation. Where VocalisMeta emits
        // `Contributor-ID: narrator:name:...`, the identifier is a fingerprint
        // of the *normalized* display name, so two spellings that normalize
        // alike carry the same key and do merge — see
        // `spellingsMergeOnKey`. That is a statement from the agent that these
        // are one person, rather than this query deciding it from the letters.
        #expect(narrators.map(\.name) == ["Andy Serkis", "celia imrie", "Celia Imrie"])
        #expect(narrators.first(where: { $0.name == "Celia Imrie" })?.bookCount == 1)
        #expect(narrators.first(where: { $0.name == "celia imrie" })?.bookCount == 1)
    }

    @Test("Books with no narrator are left out entirely")
    func missingNarrators() throws {
        let store = try seed(books: [
            ("Wyrd Sisters", ["Celia Imrie"], nil),
            ("Undocumented", [], nil),
        ])

        let narrators = try store.narrators(sectionID: "srv:2")
        #expect(narrators.map(\.name) == ["Celia Imrie"])
    }

    @Test("A book narrated by two people is counted for both")
    func multipleNarratorsPerBook() throws {
        let store = try seed(books: [
            ("Good Omens", ["Terry Jones", "Peter Serafinowicz"], nil),
        ])

        let narrators = try store.narrators(sectionID: "srv:2")
        #expect(Set(narrators.map(\.name)) == ["Terry Jones", "Peter Serafinowicz"])
        #expect(narrators.allSatisfy { $0.bookCount == 1 })
    }

    @Test("Covers are collected up to the limit, in title order")
    func coversAreCollected() throws {
        let store = try seed(books: [
            ("A Book", ["Celia Imrie"], "/t/a"),
            ("B Book", ["Celia Imrie"], "/t/b"),
            ("C Book", ["Celia Imrie"], "/t/c"),
        ])

        let narrators = try store.narrators(sectionID: "srv:2", coversPerNarrator: 2)
        #expect(narrators.first?.covers == ["/t/a", "/t/b"])
    }

    @Test("Books by one narrator come back in title order")
    func booksByNarrator() throws {
        let store = try seed(books: [
            ("Wyrd Sisters", ["Celia Imrie"], nil),
            ("Equal Rites", ["Celia Imrie"], nil),
            ("Mort", ["Andy Serkis"], nil),
        ])

        let books = try store.books(byNarrator: "Celia Imrie", sectionID: "srv:2")
        #expect(books.map(\.title) == ["Equal Rites", "Wyrd Sisters"])
    }

    /// A store where narrators carry `Contributor-ID:` Moods as well as
    /// `Style` values.
    ///
    /// `seed` above takes names only, which cannot express the case these
    /// tests are about: the same person spelled two ways, tied together by an
    /// identity the agent supplied.
    private func seedIdentified(
        _ books: [(key: String, title: String, styles: [String], moods: [String])]
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
        for entry in books {
            var fields = "\"ratingKey\":\"\(entry.key)\",\"title\":\"\(entry.title)\""
            if !entry.styles.isEmpty {
                let styles = entry.styles.map { "{\"tag\":\"\($0)\"}" }.joined(separator: ",")
                fields += ",\"Style\":[\(styles)]"
            }
            if !entry.moods.isEmpty {
                let moods = entry.moods.map { "{\"tag\":\"\($0)\"}" }.joined(separator: ",")
                fields += ",\"Mood\":[\(moods)]"
            }

            let book = try JSONDecoder().decode(PlexBook.self, from: Data("{\(fields)}".utf8))
            let track = try JSONDecoder().decode(PlexTrack.self, from: Data("""
            {"ratingKey":"t\(entry.key)","key":"/library/metadata/t\(entry.key)","title":"Part 1",
             "index":1,"duration":600000,
             "Media":[{"Part":[{"id":"p\(entry.key)","key":"/p\(entry.key)","updatedAt":1}]}]}
            """.utf8))
            try store.cache(book: book, tracks: [track], chapters: [], sectionID: "srv:2")
        }
        return store
    }

    /// Two spellings, one identity, one entry.
    ///
    /// This is what the canonical key buys: without it these are two people on
    /// the Narrators page with one book each, which is what a name-keyed
    /// grouping has to conclude.
    @Test("Two spellings sharing a canonical key are one narrator")
    func spellingsMergeOnKey() throws {
        let store = try seedIdentified([
            (
                key: "1", title: "A Book", styles: ["Scott Brick"],
                moods: ["Contributor-ID: narrator:name:843d303c74d34459 = Scott Brick"]
            ),
            (
                key: "2", title: "B Book", styles: ["Scott  Brick"],
                moods: ["Contributor-ID: narrator:name:843d303c74d34459 = Scott  Brick"]
            ),
        ])

        let narrators = try store.narrators(sectionID: "srv:2")
        #expect(narrators.count == 1)
        #expect(narrators.first?.bookCount == 2)

        // The page behind the row shows both books, or the count on the row is
        // a number the page contradicts.
        let books = try store.books(byNarrator: "Scott Brick", sectionID: "srv:2")
        #expect(books.map(\.title) == ["A Book", "B Book"])
    }

    /// A narrator with no identity at all is still a narrator.
    ///
    /// The `Style` value alone is enough — most narrators on most libraries
    /// have no provider page and the agent emits no `Contributor-ID:` for
    /// them. Requiring one before showing a name would empty the screen for
    /// exactly the libraries that need it most.
    @Test("A narrator with no Contributor-ID groups by name as before")
    func styleOnlyNarratorsGroupByName() throws {
        let store = try seedIdentified([
            (key: "1", title: "A Book", styles: ["Simon Vance"], moods: []),
            (key: "2", title: "B Book", styles: ["Simon Vance"], moods: []),
        ])

        let narrators = try store.narrators(sectionID: "srv:2")
        #expect(narrators.map(\.name) == ["Simon Vance"])
        #expect(narrators.first?.bookCount == 2)
    }

    /// Mixed evidence across a library, which is the ordinary case.
    ///
    /// One recording names a narrator with an identity and another does not.
    /// The identity is learned section-wide, so both books land under one
    /// entry — keying the second by name while the first is keyed by identity
    /// would split one person in two, which is worse than the grouping this
    /// replaced rather than better.
    @Test("An identity learned on one book applies to the same name on another")
    func identityAppliesSectionWide() throws {
        let store = try seedIdentified([
            (
                key: "1", title: "A Book", styles: ["Euan Morton"],
                moods: ["Contributor-ID: narrator:name:9451f1d4ca2e1323 = Euan Morton"]
            ),
            (key: "2", title: "B Book", styles: ["Euan Morton"], moods: []),
        ])

        let narrators = try store.narrators(sectionID: "srv:2")
        #expect(narrators.count == 1)
        #expect(narrators.first?.bookCount == 2)
    }

    /// The precedence, where one recording credits a person both ways.
    ///
    /// A provider-backed identity outranks the deterministic name-derived one
    /// *for that credit*. Two spellings are used deliberately: with the same
    /// spelling on both books the outcome is one entry either way — grouped by
    /// the shared Audible key if the precedence is right, and grouped by the
    /// matching name if it is wrong — so the assertion would hold against the
    /// bug it exists to catch.
    ///
    /// With the spellings differing, only the key can merge them. Pick the
    /// name-derived identity for the first book and it carries a key the second
    /// book does not share, the names do not match either, and the screen shows
    /// two readers where there is one.
    @Test("A provider-backed identity outranks a name-derived one")
    func providerIdentityWins() throws {
        let store = try seedIdentified([
            (
                key: "1", title: "A Book", styles: ["Scott Brick"],
                moods: [
                    "Contributor-ID: narrator:name:843d303c74d34459 = Scott Brick",
                    "Contributor-ID: narrator:audible:B002SQ5DR4 = Scott Brick",
                ]
            ),
            (
                key: "2", title: "B Book", styles: ["Scott B. Brick"],
                moods: ["Contributor-ID: narrator:audible:B002SQ5DR4 = Scott B. Brick"]
            ),
        ])

        let narrators = try store.narrators(sectionID: "srv:2")
        #expect(narrators.count == 1)
        #expect(narrators.first?.bookCount == 2)
    }

    /// The reported library, in the shape the server actually sends it.
    @Test("A twelve-narrator recording lists twelve narrators")
    func dunesNarrators() throws {
        let names = [
            "Scott Brick", "Orlagh Cassidy", "Euan Morton", "Simon Vance",
            "Ilyana Kadushin", "Byron Jennings", "David R. Gordon", "Jason Culp",
            "Kent Broadhurst", "Oliver Wyman", "Patricia Kilgarriff", "Scott Sowers",
        ]
        let hashes = [
            "843d303c74d34459", "5140cd76fbda6db2", "9451f1d4ca2e1323", "8974f444009ade2c",
            "56106aed96f23cea", "d906a75165f80759", "7e6d270133413e54", "442338e7e4154bc8",
            "fb716e091291d3e5", "182a753d577207fa", "34a7f17dc9114b51", "6f3eb6700d88ada1",
        ]
        // Destructured rather than `$0`/`$1`: `zip` yields one tuple argument,
        // and shorthand tuple splatting has not been a thing since Swift 3.
        let moods = zip(names, hashes).map { name, hash in
            "Contributor-ID: narrator:name:\(hash) = \(name)"
        }

        let store = try seedIdentified([
            (key: "154912", title: "Dune", styles: names, moods: moods),
        ])

        let narrators = try store.narrators(sectionID: "srv:2")
        #expect(narrators.count == 12)
        #expect(Set(narrators.map(\.name)) == Set(names))
        #expect(narrators.allSatisfy { $0.bookCount == 1 })
    }

    /// Two recordings, two different provider-scoped keys, one display name.
    ///
    /// The integration document forbids merging two different provider-scoped
    /// keys just because their display names match, so neither key wins here.
    /// The name does the grouping instead, which puts both books under one
    /// entry — where they would have been anyway before identities existed —
    /// without either key being asserted as the other.
    @Test("Two conflicting keys fall back to grouping by name")
    func conflictingKeysFallBackToName() throws {
        let store = try seedIdentified([
            (
                key: "1", title: "A Book", styles: ["Ray Porter"],
                moods: ["Contributor-ID: narrator:audible:B002SQ5DR4 = Ray Porter"]
            ),
            (
                key: "2", title: "B Book", styles: ["Ray Porter"],
                moods: ["Contributor-ID: narrator:librivox:20 = Ray Porter"]
            ),
        ])

        let narrators = try store.narrators(sectionID: "srv:2")
        #expect(narrators.count == 1)
        #expect(narrators.first?.bookCount == 2)

        let books = try store.books(byNarrator: "Ray Porter", sectionID: "srv:2")
        #expect(books.map(\.title) == ["A Book", "B Book"])
    }
}
