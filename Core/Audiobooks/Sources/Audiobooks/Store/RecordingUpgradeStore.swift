import Foundation
import CryptoKit
import GRDB
import PlexKit

public struct RecordingUpgradeStore: Sendable {
    private let database: AudiobookDatabase
    public init(database: AudiobookDatabase) { self.database = database }
    public enum Failure: LocalizedError {
        case unavailable, changed, copied, position, empty
        public var errorDescription: String? {
            switch self {
            case .unavailable: "A current validated recording-upgrade declaration is required. Reload the book's metadata and try again."
            case .changed: "Saved data changed during this review. Review the latest state before copying."
            case .copied: "This recording upgrade has already been copied. The original data is still retained."
            case .position: "The saved position does not fit the known recording length. Keep the current position and review the recordings."
            case .empty: "Select the saved data you want to copy."
            }
        }
    }
    public struct Summary: Sendable {
        public let identity: String
        public let title: String
        public let durationMs: Int?
        public let positionMs: Int?
        public let finished: Bool
        public let bookmarks: Int
        public let sessions: Int
    }
    public struct Review: Sendable, Identifiable {
        public var id: String { upgrade.id }
        public let bookRatingKey: String
        public let upgrade: VocalisMetaV4.Upgrade
        public let previous: Summary
        public let current: Summary
        public let conflicts: [String]
        public let fingerprint: String
        public let alreadyCopied: Bool
        public var canCopyPosition: Bool {
            guard let position = previous.positionMs, let length = current.durationMs, length > 0 else { return false }
            return position >= 0 && position <= length
        }
    }
    public struct Recovery: Sendable {
        public let id: String
        public let bookRatingKey: String
        public let data: Data
        public let previousPosition: ProgressRecord?
        public let observedRevision: Int?
    }

    public func review(bookRatingKey: String, upgradeID: String) throws -> Review {
        try database.writer.read { db in try Self.review(bookRatingKey: bookRatingKey, upgradeID: upgradeID, db: db) }
    }

    /// The source is never moved/deleted. Copied row IDs are deterministic for
    /// this declaration; all pre-copy source/target state is archived atomically.
    @discardableResult
    public func confirm(_ reviewed: Review, usePreviousPosition: Bool, copyBookmarks: Bool, copyHistory: Bool, now: Date = Date()) throws -> Int {
        guard usePreviousPosition || copyBookmarks || copyHistory else { throw Failure.empty }
        return try database.writer.write { db in
            let latest = try Self.review(bookRatingKey: reviewed.bookRatingKey, upgradeID: reviewed.upgrade.id, db: db)
            guard latest.fingerprint == reviewed.fingerprint else { throw Failure.changed }
            guard !latest.alreadyCopied else { throw Failure.copied }
            let snapshot = try Self.relevantSnapshot(db, upgrade: latest.upgrade, now: now)
            let data = try Self.encode(snapshot)
            _ = try ListeningBackupStore.inspect(data)
            if usePreviousPosition && !latest.canCopyPosition { throw Failure.position }
            let source = snapshot.books.filter { $0.identity == latest.upgrade.previous }
            if copyBookmarks, let length = latest.current.durationMs,
               source.flatMap(\.bookmarks).contains(where: { $0.deletedAt == nil && $0.absoluteMs > length }) { throw Failure.position }
            let id = Self.id(latest.upgrade)
            try db.execute(sql: "INSERT INTO identity_upgrade_backups (id, previous_identity, current_identity, created_at, payload) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, latest.upgrade.previous, latest.upgrade.current, now, data])
            let copies = source.map { item -> ListeningBackup.Book in
                var result = item
                result.identity = latest.upgrade.current
                result.progress = nil; result.settings = nil; result.pendingActions = []
                result.bookmarks = copyBookmarks ? item.bookmarks.map { bookmark in
                    var copied = bookmark
                    copied.id = "copied-" + Self.hash(id + "|bookmark|" + bookmark.id)
                    return copied
                } : []
                result.sessions = copyHistory ? item.sessions.map { session in
                    var copied = session
                    copied.id = "copied-" + Self.hash(id + "|session|" + session.id)
                    return copied
                } : []
                return result
            }
            var count = try ListeningBackupStore.merge(ListeningBackup(createdAt: now, books: copies), db: db)
            if usePreviousPosition, let progress = Self.latestProgress(source) {
                try Self.writePosition(progress, bookRatingKey: reviewed.bookRatingKey, now: now, db: db)
                count += 1
            }
            return count
        }
    }

    public func recovery(bookRatingKey: String) throws -> Recovery? {
        try database.writer.read { db in
            guard let book = try BookRecord.fetchOne(db, key: bookRatingKey), let identity = book.identityKey,
                  let row = try Row.fetchOne(db, sql: "SELECT id, payload FROM identity_upgrade_backups WHERE current_identity = ? ORDER BY created_at DESC LIMIT 1", arguments: [identity]) else { return nil }
            let data: Data = row["payload"]
            let snapshot = try ListeningBackupStore.inspect(data)
            return Recovery(id: row["id"], bookRatingKey: bookRatingKey, data: data,
                previousPosition: Self.latestProgress(snapshot.books.filter { $0.identity == identity }),
                observedRevision: try ProgressRecord.fetchOne(db, key: bookRatingKey)?.revision)
        }
    }

    /// Explicit restoration of the pre-copy position/completion only. Imported
    /// bookmarks/history and original source rows are deliberately retained.
    public func restoreEarlierPosition(_ recovery: Recovery, now: Date = Date()) throws {
        try database.writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT current_identity, payload FROM identity_upgrade_backups WHERE id = ?", arguments: [recovery.id]),
                  let book = try BookRecord.fetchOne(db, key: recovery.bookRatingKey),
                  book.identityKey == row["current_identity"] as String?,
                  try ProgressRecord.fetchOne(db, key: book.ratingKey)?.revision == recovery.observedRevision else { throw Failure.changed }
            let data: Data = row["payload"]
            let snapshot = try ListeningBackupStore.inspect(data)
            guard let progress = Self.latestProgress(snapshot.books.filter { $0.identity == book.identityKey }) else { throw Failure.unavailable }
            guard let length = book.durationMs, progress.absoluteMs <= length else { throw Failure.position }
            try Self.writePosition(progress, bookRatingKey: book.ratingKey, now: now, db: db)
        }
    }

    private static func review(bookRatingKey: String, upgradeID: String, db: Database) throws -> Review {
        guard let book = try BookRecord.fetchOne(db, key: bookRatingKey), book.v4Available, !book.detailNeedsRefresh,
              let data = book.v4Payload, let identity = book.identityKey,
              let packet = try? VocalisMetaV4.decodePayload(data, recordingKey: identity),
              let upgrade = packet.identityUpgrades.first(where: { $0.id == upgradeID }) else { throw Failure.unavailable }
        let snapshot = try relevantSnapshot(db, upgrade: upgrade, now: Date(timeIntervalSince1970: 0))
        let previousBook = try BookRecord.filter(Column("identity_key") == upgrade.previous).fetchOne(db)
            ?? Data.fetchOne(db, sql: "SELECT payload FROM recording_metadata_archive WHERE identity_key = ?", arguments: [upgrade.previous]).flatMap { try JSONDecoder().decode(BookRecord.self, from: $0) }
        func summary(_ identity: String, book: BookRecord?) -> Summary {
            let rows = snapshot.books.filter { $0.identity == identity }
            let progress = latestProgress(rows)
            return Summary(identity: identity, title: book?.title ?? "Previous recording", durationMs: book?.durationMs,
                positionMs: progress?.absoluteMs, finished: progress?.finishedAt != nil,
                bookmarks: Set(rows.flatMap(\.bookmarks).filter { $0.deletedAt == nil }.map(\.id)).count,
                sessions: Set(rows.flatMap(\.sessions).map(\.id)).count)
        }
        var conflicts = upgrade.reasons
        if let previousBook {
            if let a = previousBook.language, let b = book.language, a != b { conflicts.append("Local language differs") }
            if let a = previousBook.edition, let b = book.edition, a != b { conflicts.append("Local abridgment differs") }
            if let a = previousBook.durationMs, let b = book.durationMs, abs(a - b) > max(60000, Int(Double(min(a, b)) * 0.005)) { conflicts.append("Local recording length differs") }
        }
        let metadataEncoder = JSONEncoder()
        metadataEncoder.outputFormatting = [.sortedKeys]
        let metadata = try metadataEncoder.encode([book] + (previousBook.map { [$0] } ?? []))
        let fingerprint = hash(String(decoding: try encode(snapshot), as: UTF8.self) + "|" + data.base64EncodedString() + "|" + metadata.base64EncodedString())
        return Review(bookRatingKey: bookRatingKey, upgrade: upgrade, previous: summary(upgrade.previous, book: previousBook),
            current: summary(upgrade.current, book: book), conflicts: conflicts, fingerprint: fingerprint,
            alreadyCopied: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM identity_upgrade_backups WHERE id = ?", arguments: [id(upgrade)]) == 1)
    }
    private static func relevantSnapshot(_ db: Database, upgrade: VocalisMetaV4.Upgrade, now: Date) throws -> ListeningBackup {
        let all = try ListeningBackupStore.snapshot(db, now: now)
        return ListeningBackup(createdAt: now, books: all.books.filter { $0.identity == upgrade.previous || $0.identity == upgrade.current })
    }
    private static func latestProgress(_ books: [ListeningBackup.Book]) -> ProgressRecord? {
        books.compactMap(\.progress).max { a, b in a.changedAt == b.changedAt ? a.revision < b.revision : a.changedAt < b.changedAt }
    }
    private static func writePosition(_ original: ProgressRecord, bookRatingKey: String, now: Date, db: Database) throws {
        let old = try ProgressRecord.fetchOne(db, key: bookRatingKey)
        var progress = original
        progress.bookRatingKey = bookRatingKey; progress.changedAt = now
        progress.revision = max(original.revision, old?.revision ?? 0) + 1
        progress.syncedAt = nil; progress.syncedOffsetMs = nil; progress.dirty = true; progress.cloudDirty = true
        try progress.save(db)
        if progress.finishedAt == nil && old?.finishedAt != nil {
            try SyncStore.enqueue(db, bookRatingKey: bookRatingKey, kind: .unfinished, absoluteMs: progress.absoluteMs, at: now.addingTimeInterval(-0.001), revision: progress.revision)
        }
        try SyncStore.enqueue(db, bookRatingKey: bookRatingKey, kind: .position, absoluteMs: progress.absoluteMs, at: now, revision: progress.revision)
        if progress.finishedAt != nil {
            try SyncStore.enqueue(db, bookRatingKey: bookRatingKey, kind: .finished, absoluteMs: progress.absoluteMs, at: now.addingTimeInterval(0.001), revision: progress.revision)
        }
    }
    private static func encode(_ backup: ListeningBackup) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(backup)
    }
    private static func id(_ upgrade: VocalisMetaV4.Upgrade) -> String { hash(upgrade.id) }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}
