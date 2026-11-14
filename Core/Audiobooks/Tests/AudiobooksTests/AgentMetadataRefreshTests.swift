import Foundation
import Testing
import PlexKit
@testable import Audiobooks

@Suite("VocalisMeta detail projection and refresh backlog")
struct AgentMetadataRefreshTests {
    @Test("Authoritative detail removes rejected work data but keeps independent narrator and recording facets")
    func authoritativeNamespaceRemoval() throws {
        let fixture = try FollowupFixture()
        let initial: [String: Any] = ["updatedAt": 1000, "Mood": [
            ["tag": "Series: Zeta"], ["tag": "Series: Alpha"], ["tag": "Sequence: Zeta #2"],
            ["tag": "Work-ID: openlibrary:OL12345W"], ["tag": "Work-Published: 1950"],
            ["tag": "Contributor-ID: author:openlibrary:OL2162289A = Old work author"]]]
        try fixture.cache(fields: initial)
        #expect(try fixture.library.credits(bookRatingKey: "900").series == ["Zeta", "Alpha"])
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 123)
        let listing = try fixture.book(fields: ["updatedAt": 2000])
        try fixture.library.cacheBookList([listing], sectionID: "A:2")
        #expect(try fixture.library.credits(bookRatingKey: "900").workIdentity != nil)
        #expect(try fixture.library.booksAwaitingDetail(sectionID: "A:2") == ["900"])
        let accepted: [String: Any] = ["updatedAt": 2000, "year": 2008, "originallyAvailableAt": "2008-03-14",
            "studio": "Swedish Publisher", "rating": 9.4, "Style": [["tag": "Mark Levengood"]], "Mood": [
                ["tag": "Language: Swedish"], ["tag": "Rating-Source: Ljudboksarkivet"], ["tag": "Rating-Count: 418"],
                ["tag": "Contributor-ID: narrator:name:e12832aa5ccb9345 = Mark Levengood"]]]
        try fixture.cache(fields: accepted)
        let credits = try fixture.library.credits(bookRatingKey: "900")
        #expect(credits.workIdentity == nil && credits.workPublishedYear == nil && credits.series.isEmpty)
        #expect(credits.contributors.count == 1 && credits.contributors.first?.role == "narrator")
        #expect(credits.narrators == ["Mark Levengood"])
        #expect(credits.recordingReleaseDate == "2008-03-14" && credits.publisher == "Swedish Publisher")
        #expect(credits.productionLine?.contains("4.7/5") == true && credits.productionLine?.contains("418") == true)
        #expect(try fixture.library.booksAwaitingDetail(sectionID: "A:2").isEmpty)
        #expect(try fixture.progress.progress(bookRatingKey: "900")?.absoluteMs == 123)
    }

    @Test("Changed detail work survives the 50-book cap and repeated unchanged list refreshes")
    func cappedBacklogPersists() throws {
        let fixture = try FollowupFixture()
        let keys = (1000..<1052).map(String.init)
        for key in keys { try fixture.cache(key, fields: ["updatedAt": 1000]) }
        let list = try keys.map { try fixture.book($0, fields: ["updatedAt": 2000]) }
        try fixture.library.cacheBookList(list, sectionID: "A:2")
        let first = try fixture.library.booksAwaitingDetail(sectionID: "A:2")
        #expect(first.count == 50)
        for key in first {
            try fixture.library.noteDetailAttempt(ratingKey: key)
            try fixture.cache(key, fields: ["updatedAt": 2000])
        }
        try fixture.library.cacheBookList(list, sectionID: "A:2")
        let remaining = try fixture.library.booksAwaitingDetail(sectionID: "A:2")
        #expect(remaining.count == 2 && Set(remaining).isDisjoint(with: Set(first)))
        try fixture.library.noteDetailAttempt(ratingKey: remaining[0])
        #expect(try fixture.library.booksAwaitingDetail(sectionID: "A:2").first == remaining[1])
    }

    @Test("A partial list keeps richer recording metadata until authoritative detail arrives")
    func listDoesNotEraseFacets() throws {
        let fixture = try FollowupFixture()
        try fixture.cache(fields: ["updatedAt": 1000, "studio": "Publisher", "rating": 8.6,
            "originallyAvailableAt": "2019-02-28", "Mood": [["tag": "Language: Swedish"], ["tag": "Rating-Source: Audible"]]])
        try fixture.library.cacheBookList([fixture.book(fields: ["updatedAt": 1000])], sectionID: "A:2")
        let credits = try fixture.library.credits(bookRatingKey: "900")
        #expect(credits.language == "Swedish" && credits.publisher == "Publisher" && credits.rating == 8.6)
        #expect(credits.recordingReleaseDate == "2019-02-28")
        #expect(try fixture.library.booksAwaitingDetail(sectionID: "A:2").isEmpty)
    }
    @Test("Omitted GUIDs preserve the known recording identity and listening state")
    func missingGuidPreservesIdentity() throws {
        let fixture = try FollowupFixture()
        let guid = "com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en"
        try fixture.cache(fields: ["guid": guid])
        try fixture.progress.recordPosition(bookRatingKey: "900", absoluteMs: 123)
        try fixture.library.cacheBookList([fixture.book()], sectionID: "A:2")
        #expect(try fixture.library.book(ratingKey: "900")?.identityKey == "spokenmeta:audible:us:B08G9PRS1K")
        #expect(try fixture.progress.progress(bookRatingKey: "900")?.absoluteMs == 123)
        try fixture.cache()
        #expect(try fixture.library.book(ratingKey: "900")?.identityKey == "spokenmeta:audible:us:B08G9PRS1K")
        #expect(try fixture.progress.progress(bookRatingKey: "900")?.absoluteMs == 123)
    }

    @Test("A changed rating provider cannot inherit another provider's vote count")
    func ratingProviderChange() throws {
        let fixture = try FollowupFixture()
        try fixture.cache(fields: ["rating": 9.4, "Mood": [["tag": "Rating-Source: Audible"], ["tag": "Rating-Count: 1000"]]])
        try fixture.library.cacheBookList([fixture.book(fields: ["Mood": [["tag": "Rating-Source: Ljudboksarkivet"]]])], sectionID: "A:2")
        let credits = try fixture.library.credits(bookRatingKey: "900")
        #expect(credits.ratingSource == "Ljudboksarkivet" && credits.ratingCount == nil && credits.rating == nil)
    }

    @Test("Series standing and next-book suggestions follow the primary membership within this library")
    func primarySeriesNavigation() throws {
        let fixture = try FollowupFixture()
        try fixture.cache("900", fields: ["Mood": [
            ["tag": "Series: Zeta"], ["tag": "Sequence: Zeta #2"],
            ["tag": "Series: Alpha"], ["tag": "Sequence: Alpha #100"]]])
        try fixture.cache("901", fields: ["Mood": [["tag": "Series: Zeta"], ["tag": "Sequence: Zeta #3"]]])
        try fixture.cache("902", fields: ["Mood": [["tag": "Series: Alpha"], ["tag": "Sequence: Alpha #101"]]])
        try fixture.cache("903", server: "B", fields: ["Mood": [["tag": "Series: Zeta"], ["tag": "Sequence: Zeta #4"]]])
        let standing = try #require(try fixture.library.standing(ofBook: "900"))
        #expect(standing.series == "Zeta" && standing.position == "2" && standing.heldInLibrary == 2)
        let next = try #require(try fixture.library.nextInSeries(after: "900"))
        #expect(next.seriesTitle == "Zeta" && next.book.ratingKey == "901")
    }

}
