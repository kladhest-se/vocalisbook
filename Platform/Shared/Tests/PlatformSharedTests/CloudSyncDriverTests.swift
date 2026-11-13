import CloudKit
import Foundation
import Testing
import Audiobooks
@testable import PlatformShared

@Suite("CloudKit record boundary")
struct CloudSyncDriverTests {
    @Test("Acknowledging an older save keeps an edit made in flight dirty")
    func editDuringSave() throws {
        let db = try AudiobookDatabase.inMemory()
        let bookmarks = BookmarkStore(database: db)
        let store = CloudSyncStore(database: db)
        let bookmark = try bookmarks.add(bookRatingKey: "900", absoluteMs: 100)
        let outgoing = try #require(store.pendingChanges().first)
        let saved = CloudSyncDriver.apply(outgoing, to: CKRecord(
            recordType: outgoing.kind.rawValue,
            recordID: .init(recordName: outgoing.recordName)
        ))
        try bookmarks.setLabel("Changed while saving", id: bookmark.id)
        try CloudSyncDriver.acknowledgeSavedRecords([saved], in: store)
        let pending = try #require(store.pendingChanges().first)
        #expect(pending.revision == outgoing.revision + 1)
        #expect(pending.fields["label"]?.stringValue == "Changed while saving")
    }

    @Test("A full progress snapshot clears a former finished date")
    func resetFinishedBook() {
        let record = CKRecord(recordType: "Progress", recordID: .init(recordName: "Progress-book"))
        record["finishedAt"] = Date() as CKRecordValue
        record["futureField"] = "preserve me" as CKRecordValue
        let local = CloudRecord(kind: .progress, id: "book", revision: 2,
                                fields: ["absoluteMs": .int(0), "changedAt": .date(Date())])
        _ = CloudSyncDriver.apply(local, to: record)
        #expect(record["finishedAt"] == nil)
        #expect(record["futureField"] as? String == "preserve me")
    }

    @Test("Removing a bookmark label survives a CloudKit and store round trip")
    func clearLabel() throws {
        let db = try AudiobookDatabase.inMemory()
        let bookmarks = BookmarkStore(database: db)
        let store = CloudSyncStore(database: db)
        let bookmark = try bookmarks.add(bookRatingKey: "900", absoluteMs: 100, label: "Old")
        let before = try #require(store.pendingChanges().first)
        let record = CloudSyncDriver.apply(before, to: CKRecord(
            recordType: before.kind.rawValue, recordID: .init(recordName: before.recordName)
        ))
        let cleared = CloudRecord(kind: .bookmark, id: bookmark.id, revision: before.revision + 1,
                                  fields: ["bookRatingKey": .string("900"), "absoluteMs": .int(100)])
        _ = CloudSyncDriver.apply(cleared, to: record)
        #expect(record["label"] == nil)
        try store.apply([#require(CloudSyncDriver.cloudRecord(from: record))])
        #expect(try bookmarks.bookmarks(bookRatingKey: "900").first?.label == nil)
    }

    @Test("Whole and fractional playback speeds retain their numeric type", arguments: [1.0, 2.0, 1.5])
    func speedType(rate: Double) throws {
        let record = CKRecord(recordType: "BookSettings", recordID: .init(recordName: "BookSettings-book"))
        record["rate"] = NSNumber(value: rate)
        let mapped = try #require(CloudSyncDriver.cloudRecord(from: record))
        #expect(mapped.fields["rate"]?.doubleValue == rate)
    }
}
