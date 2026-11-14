import Foundation
import GRDB
import Testing
import PlexKit

@testable import Audiobooks

struct V4Fixture {
    static func native(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Core/PlexKit/Tests/PlexKitTests/Fixtures/VocalisMeta/v4/\(name).json").standardizedFileURL
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let container = try #require(root["MediaContainer"] as? [String: Any])
        return try #require((container["Metadata"] as? [[String: Any]])?.first)
    }
    static func key(_ native: [String: Any]) -> String { native["ratingKey"] as? String ?? "101" }
    static func seed(_ fixture: FollowupFixture, name: String) throws -> String {
        let native = try native(name), key = key(native)
        try fixture.cache(key, fields: native)
        return key
    }
}

@Suite("V4 cache, native precedence and recording review")
struct MetadataV4IntegrationTests {
    @Test("V4 primary series does not depend on native Mood or chunk order")
    func declaredPrimarySeries() throws {
        let fixture = try FollowupFixture()
        var native = try V4Fixture.native("fresh_recording")
        native["Mood"] = (native["Mood"] as? [[String: String]] ?? []).sorted { ($0["tag"] ?? "") > ($1["tag"] ?? "") }
        let key = V4Fixture.key(native)
        try fixture.cache(key, fields: native)
        let credits = try fixture.library.credits(bookRatingKey: key)
        #expect(credits.series.first == "Saga")
        let info = try fixture.library.metadataInfo(bookRatingKey: key)
        #expect(info.available && info.packet?.series.memberships.count == 2)
        #expect(info.packet?.series.memberships.allSatisfy { $0.providerID?.source == "audible" && $0.providerID?.scope == "us" } == true)
        #expect(!credits.authors.contains { $0.hasPrefix(VocalisMetaV4.prefix) })
    }
    @Test("Explicit work and series tombstones remove only their owned metadata")
    func explicitClears() throws {
        let fixture = try FollowupFixture()
        let key = try V4Fixture.seed(fixture, name: "fresh_recording")
        try fixture.progress.recordPosition(bookRatingKey: key, absoluteMs: 123)
        try BookmarkStore(database: fixture.db).add(bookRatingKey: key, absoluteMs: 123)
        #expect(try fixture.library.credits(bookRatingKey: key).workIdentity != nil)
        _ = try V4Fixture.seed(fixture, name: "rejected_work_is_explicitly_cleared")
        let credits = try fixture.library.credits(bookRatingKey: key)
        #expect(credits.workIdentity == nil && credits.workPublishedYear == nil)
        #expect(!credits.narrators.isEmpty && !credits.contributors.isEmpty)
        #expect(try fixture.progress.progress(bookRatingKey: key)?.absoluteMs == 123)
        #expect(try BookmarkStore(database: fixture.db).count(bookRatingKey: key) == 1)
        _ = try V4Fixture.seed(fixture, name: "manual_override_and_series_clear")
        #expect(try fixture.library.credits(bookRatingKey: key).series.isEmpty)
        #expect(try fixture.library.book(ratingKey: key)?.author != nil)
    }
    @Test("Health changes are saved even when both revision tokens stay unchanged")
    func healthWithoutRevisionChange() throws {
        let fixture = try FollowupFixture()
        let key = try V4Fixture.seed(fixture, name: "fresh_recording")
        let before = try #require(try fixture.library.metadataInfo(bookRatingKey: key).packet)
        _ = try V4Fixture.seed(fixture, name: "provider_unavailable_preserves_revisions")
        let after = try #require(try fixture.library.metadataInfo(bookRatingKey: key).packet)
        #expect(after.metadataRevision == before.metadataRevision && after.artworkRevision == before.artworkRevision)
        #expect(after.payloadData != before.payloadData)
        #expect(after.fields.values.contains { $0.stale || $0.state == .unavailable })
        #expect(try fixture.library.credits(bookRatingKey: key).series.first == "Saga")
    }
    @Test("Broken and disabled v4 retain prior packet information without manufacturing clears")
    func missingOrBrokenPacket() throws {
        let fixture = try FollowupFixture()
        let key = try V4Fixture.seed(fixture, name: "fresh_recording")
        let previous = try fixture.library.book(ratingKey: key)?.v4Payload
        var native = try V4Fixture.native("fresh_recording")
        native["Mood"] = [["tag": "VocalisMeta-v4: broken"]]
        try fixture.cache(key, fields: native)
        let info = try fixture.library.metadataInfo(bookRatingKey: key)
        #expect(!info.available && info.packet?.payloadData == previous)
        #expect(try fixture.library.credits(bookRatingKey: key).series.first == "Saga")
        native["Mood"] = [] as [[String: String]]
        native["title"] = "Native manual title"
        try fixture.cache(key, fields: native)
        #expect(try fixture.library.book(ratingKey: key)?.title == "Native manual title")
        #expect(try fixture.library.book(ratingKey: key)?.v4Payload == previous)
    }
    @Test("Native field locks override an unchanged agent packet and invalidate its provenance")
    func nativeOverrides() throws {
        let fixture = try FollowupFixture()
        var native = try V4Fixture.native("fresh_recording")
        let key = V4Fixture.key(native)
        native["title"] = "Manual Plex title"
        native["Style"] = [["tag": "Manual reader"]]
        try fixture.cache(key, fields: native)
        let info = try fixture.library.metadataInfo(bookRatingKey: key)
        #expect(info.mismatches.contains("title") && info.mismatches.contains("narrators"))
        #expect(try fixture.library.book(ratingKey: key)?.title == "Manual Plex title")
        #expect(try fixture.library.credits(bookRatingKey: key).narrators == ["Manual reader"])
    }
    @Test("Independent artwork changes schedule detail refresh and replace the cover version at the same URL")
    func coverRevisionRefresh() throws {
        let fixture = try FollowupFixture()
        let key = try V4Fixture.seed(fixture, name: "fresh_recording")
        let before = try #require(try fixture.library.book(ratingKey: key))
        let native = try V4Fixture.native("same_key_artwork_replacement")
        let listing = try fixture.book(key, fields: native)
        try fixture.library.cacheBookList([listing], sectionID: "A:2")
        #expect(try fixture.library.booksAwaitingDetail(sectionID: "A:2").contains(key))
        try fixture.cache(key, fields: native)
        let after = try #require(try fixture.library.book(ratingKey: key))
        #expect(before.thumb == after.thumb && before.plexUpdatedAt == after.plexUpdatedAt)
        #expect(before.metadataRevision == after.metadataRevision && before.artworkRevision != after.artworkRevision)
        #expect(before.artworkCacheVersion != after.artworkCacheVersion)
        #expect(try fixture.library.artworkVersions()["A\0" + (after.thumb ?? "")] == after.artworkCacheVersion)
    }
    private func upgradeFixture() throws -> (FollowupFixture, String, String) {
        let fixture = try FollowupFixture()
        let key = try V4Fixture.seed(fixture, name: "weak_local_recording")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.progress.recordPosition(bookRatingKey: key, absoluteMs: 10000, at: start)
        try BookmarkStore(database: fixture.db).add(bookRatingKey: key, absoluteMs: 10000, label: "Original")
        let sessions = SessionStore(database: fixture.db)
        try sessions.begin(bookRatingKey: key, atMs: 0, rate: 1, sectionID: "A:2", now: start)
        try sessions.end(atMs: 10000, now: start.addingTimeInterval(10))
        _ = try V4Fixture.seed(fixture, name: "verified_local_to_audible")
        try fixture.progress.recordPosition(bookRatingKey: key, absoluteMs: 20000)
        let upgrade = try #require(try fixture.library.metadataInfo(bookRatingKey: key).packet?.identityUpgrades.first)
        return (fixture, key, upgrade.id)
    }
    @Test("An advertised upgrade does nothing until a reviewed copy; originals and recovery data are retained")
    func reviewedCopy() throws {
        let (fixture, key, id) = try upgradeFixture()
        let store = RecordingUpgradeStore(database: fixture.db)
        let review = try store.review(bookRatingKey: key, upgradeID: id)
        #expect(review.previous.positionMs == 10000 && review.current.positionMs == 20000)
        #expect(review.previous.bookmarks == 1 && review.previous.sessions == 1)
        #expect(try BookmarkStore(database: fixture.db).count(bookRatingKey: key) == 0)
        #expect(try store.confirm(review, usePreviousPosition: false, copyBookmarks: true, copyHistory: true) == 2)
        #expect(try fixture.progress.progress(bookRatingKey: key)?.absoluteMs == 20000)
        #expect(try fixture.progress.progress(bookRatingKey: "@identity:" + review.upgrade.previous)?.absoluteMs == 10000)
        #expect(try BookmarkStore(database: fixture.db).count(bookRatingKey: key) == 1)
        #expect(try BookmarkStore(database: fixture.db).count(bookRatingKey: "@identity:" + review.upgrade.previous) == 1)
        let recovery = try #require(try store.recovery(bookRatingKey: key))
        #expect(try ListeningBackupStore.inspect(recovery.data).books.count == 2)
        #expect(try store.review(bookRatingKey: key, upgradeID: id).alreadyCopied)
        #expect(throws: RecordingUpgradeStore.Failure.self) { try store.confirm(review, usePreviousPosition: false, copyBookmarks: true, copyHistory: true) }
        #expect(try BookmarkStore(database: fixture.db).count(bookRatingKey: key) == 1)
    }
    @Test("A chosen previous position can be recovered back to the pre-copy state explicitly")
    func positionRecovery() throws {
        let (fixture, key, id) = try upgradeFixture()
        let store = RecordingUpgradeStore(database: fixture.db), review = try store.review(bookRatingKey: key, upgradeID: id)
        #expect(try store.confirm(review, usePreviousPosition: true, copyBookmarks: false, copyHistory: false) == 1)
        #expect(try fixture.progress.progress(bookRatingKey: key)?.absoluteMs == 10000)
        let recovery = try #require(try store.recovery(bookRatingKey: key))
        #expect(recovery.previousPosition?.absoluteMs == 20000)
        try store.restoreEarlierPosition(recovery)
        #expect(try fixture.progress.progress(bookRatingKey: key)?.absoluteMs == 20000)
        #expect(try fixture.progress.progress(bookRatingKey: key)?.dirty == true)
    }
    @Test("Changed saved state or native recording metadata invalidates an open review")
    func staleReview() throws {
        let (fixture, key, id) = try upgradeFixture()
        let store = RecordingUpgradeStore(database: fixture.db), review = try store.review(bookRatingKey: key, upgradeID: id)
        try fixture.progress.recordPosition(bookRatingKey: key, absoluteMs: 30000)
        #expect(throws: RecordingUpgradeStore.Failure.self) { try store.confirm(review, usePreviousPosition: true, copyBookmarks: true, copyHistory: true) }
        #expect(try fixture.progress.progress(bookRatingKey: key)?.absoluteMs == 30000)
        #expect(try store.recovery(bookRatingKey: key) == nil)
    }
    @Test("Unavailable declarations and positions outside the known recording cannot be copied")
    func unavailableAndOutOfRange() throws {
        let (fixture, key, id) = try upgradeFixture()
        try fixture.progress.recordPosition(bookRatingKey: "@identity:spokenmeta:local:0123456789abcdef", absoluteMs: 900000)
        let store = RecordingUpgradeStore(database: fixture.db), review = try store.review(bookRatingKey: key, upgradeID: id)
        #expect(!review.canCopyPosition)
        #expect(throws: RecordingUpgradeStore.Failure.self) { try store.confirm(review, usePreviousPosition: true, copyBookmarks: false, copyHistory: false) }
        var native = try V4Fixture.native("verified_local_to_audible")
        native["Mood"] = [["tag": "VocalisMeta-v4: broken"]]
        try fixture.cache(key, fields: native)
        #expect(throws: RecordingUpgradeStore.Failure.self) { try store.review(bookRatingKey: key, upgradeID: id) }
    }
    @Test("Explicit listening-data clearing removes recovery snapshots as well")
    func clearingRecoveryData() throws {
        let (fixture, key, id) = try upgradeFixture()
        let store = RecordingUpgradeStore(database: fixture.db), review = try store.review(bookRatingKey: key, upgradeID: id)
        _ = try store.confirm(review, usePreviousPosition: false, copyBookmarks: true, copyHistory: false)
        try fixture.db.purgeSyncedUserData()
        #expect(try store.recovery(bookRatingKey: key) == nil)
    }
}
