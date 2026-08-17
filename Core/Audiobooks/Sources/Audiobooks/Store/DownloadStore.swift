import Foundation
import GRDB

/// What is on disk, and what is on its way there.
///
/// The `download` table has existed since the first migration and nothing wrote
/// to it — the coordinator was a protocol with a TODO. This is the half that
/// needs no platform: the queue, the states, and the accounting.
public struct DownloadStore: Sendable {
    private let database: AudiobookDatabase

    public init(database: AudiobookDatabase) {
        self.database = database
    }

    /// Queues every file of a book that is not already there.
    ///
    /// Keyed by `partCacheKey`, which is the part id and the file's `updatedAt`
    /// together — so a book that was retagged on the server queues afresh rather
    /// than being considered already downloaded.
    public func enqueue(bookRatingKey: String, segments: [BookTimeline.Segment]) throws {
        try database.writer.write { db in
            for segment in segments {
                let existing = try DownloadRecord.fetchOne(db, key: segment.partCacheKey)
                if existing?.state == DownloadRecord.State.complete.rawValue { continue }

                let record = DownloadRecord(
                    partCacheKey: segment.partCacheKey,
                    bookRatingKey: bookRatingKey,
                    trackRatingKey: segment.trackRatingKey,
                    state: DownloadRecord.State.queued.rawValue,
                    bytesTotal: existing?.bytesTotal,
                    bytesDone: 0,
                    relativePath: nil,
                    completedAt: nil,
                    lastError: nil
                )
                try record.save(db)
            }
        }
    }

    public func markDownloading(partCacheKey: String, bytesDone: Int, bytesTotal: Int?) throws {
        try database.writer.write { db in
            guard var record = try DownloadRecord.fetchOne(db, key: partCacheKey) else { return }
            record.state = DownloadRecord.State.downloading.rawValue
            record.bytesDone = bytesDone
            if let bytesTotal { record.bytesTotal = bytesTotal }
            try record.save(db)
        }
    }

    public func markComplete(partCacheKey: String, relativePath: String, bytes: Int, now: Date = Date()) throws {
        try database.writer.write { db in
            guard var record = try DownloadRecord.fetchOne(db, key: partCacheKey) else { return }
            record.state = DownloadRecord.State.complete.rawValue
            record.relativePath = relativePath
            record.bytesDone = bytes
            record.bytesTotal = bytes
            record.completedAt = now
            record.lastError = nil
            try record.save(db)
        }
    }

    public func markFailed(partCacheKey: String, error: String) throws {
        try database.writer.write { db in
            guard var record = try DownloadRecord.fetchOne(db, key: partCacheKey) else { return }
            record.state = DownloadRecord.State.failed.rawValue
            record.lastError = error
            try record.save(db)
        }
    }

    /// Everything still to fetch, oldest first.
    public func pending() throws -> [DownloadRecord] {
        try database.writer.read { db in
            try DownloadRecord
                .filter([
                    DownloadRecord.State.queued.rawValue,
                    DownloadRecord.State.failed.rawValue,
                ].contains(Column("state")))
                .fetchAll(db)
        }
    }

    public func record(partCacheKey: String) throws -> DownloadRecord? {
        try database.writer.read { db in try DownloadRecord.fetchOne(db, key: partCacheKey) }
    }

    /// Where a completed file sits, relative to the downloads directory.
    ///
    /// Relative, not absolute: the container path changes between builds and
    /// between devices, and an absolute path stored today is wrong tomorrow.
    public func relativePath(forPartCacheKey key: String) throws -> String? {
        try database.writer.read { db in
            try DownloadRecord.fetchOne(db, key: key).flatMap { record in
                record.state == DownloadRecord.State.complete.rawValue ? record.relativePath : nil
            }
        }
    }

    /// How far along a whole book is.
    /// What is on disk for a book, judged against what the book currently needs.
    ///
    /// - Parameters:
    ///   - partCacheKeys: the keys the book's timeline asks for *now*. Records
    ///     for anything else are ignored, and a key with no complete record
    ///     means the book is not downloaded however many other records exist.
    ///   - fileExists: given a relative path, whether the file is really there.
    ///     Supplied by the platform, which owns the directory; this package does
    ///     not touch the filesystem.
    ///
    /// Both are optional so the cheap call still works where the answer is only
    /// a progress figure, but a screen claiming a book is downloaded should pass
    /// them.
    ///
    /// **Why keys matter.** This used to count every record filed under the
    /// book, and playback resolves a file by *part cache key* — so when that key
    /// gained a fallback for servers with no `updatedAt`, every book downloaded
    /// before the change kept complete records under its old keys and went on
    /// showing a tick and a size, while playback looked up the new key, found
    /// nothing, and streamed. A book that says it is on disk, playing over the
    /// network, with nothing on screen saying so.
    ///
    /// **Why files matter.** A record outlives the file it describes. Downloads
    /// live in Application Support, which is not purged the way Caches is, but a
    /// failed move, a restore from backup or somebody with a Finder window all
    /// produce the same thing: a row saying complete and no bytes behind it.
    public func state(
        bookRatingKey: String,
        partCacheKeys: [String]? = nil,
        fileExists: ((String) -> Bool)? = nil
    ) throws -> BookDownloadState {
        var records = try database.writer.read { db in
            try DownloadRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .fetchAll(db)
        }

        if let partCacheKeys {
            let wanted = Set(partCacheKeys)
            records = records.filter { wanted.contains($0.partCacheKey) }

            // A part with no record at all is a part not downloaded. Without
            // this, a book half-recorded under old keys reports on the half it
            // still has.
            guard records.count == wanted.count else { return .notDownloaded }
        }

        guard !records.isEmpty else { return .notDownloaded }

        if let fileExists {
            let missing = records.contains { record in
                record.state == DownloadRecord.State.complete.rawValue
                    && !(record.relativePath.map(fileExists) ?? false)
            }
            if missing { return .notDownloaded }
        }

        let complete = records.filter { $0.state == DownloadRecord.State.complete.rawValue }
        if complete.count == records.count {
            return .complete(bytes: complete.reduce(0) { $0 + ($1.bytesDone) })
        }
        if let failure = records.first(where: { $0.state == DownloadRecord.State.failed.rawValue }) {
            return .failed(failure.lastError ?? "Download failed")
        }

        // Each file counts for its share, and each file's share is however far
        // through it is.
        //
        // Summing bytes across the book does not work: a file whose size is not
        // known yet contributes nothing to the denominator, so one finished file
        // out of four read as 100% — done and total were both that one file. A
        // size is only known once its transfer has started, so during any real
        // download most of the book has none.
        let progress = records.reduce(0.0) { running, record in
            if record.state == DownloadRecord.State.complete.rawValue {
                return running + 1
            }
            guard let total = record.bytesTotal, total > 0 else {
                return running
            }
            return running + min(Double(record.bytesDone) / Double(total), 1)
        }
        let fraction = progress / Double(records.count)
        return .downloading(fraction: min(max(fraction, 0), 1))
    }

    /// Books with anything on disk, for the settings screen.
    /// Every book with anything downloaded, finished or not.
    ///
    /// Distinct from `downloadedBooks`, which only counts parts already
    /// complete: a book halfway through its transfer has bytes on disk and
    /// belongs on a screen about downloads, and is exactly the book somebody
    /// opens that screen to look at. Ordered by title so the list does not
    /// reshuffle as sizes change.
    public func booksWithDownloads() throws -> [String] {
        try database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT download.book_rating_key
                FROM download
                LEFT JOIN book ON book.rating_key = download.book_rating_key
                ORDER BY book.title_sort COLLATE NOCASE ASC
                """)
        }
    }

    /// Every file the store believes it has.
    ///
    /// For finding the ones it does not. A file whose record is gone — because
    /// the part's cache key changed, or a row was deleted without the file being
    /// removed — is invisible to the app and still occupying hundreds of
    /// megabytes.
    /// Forgets records for parts the book no longer asks for.
    ///
    /// Their files then have nothing pointing at them, and the launch sweep
    /// removes them — which is how a library downloaded under the old cache keys
    /// gets its disk space back rather than holding it for ever under names
    /// nothing will ever look up again.
    ///
    /// Returns how many rows went, so a caller can say something if it wants to.
    @discardableResult
    public func discardStale(bookRatingKey: String, keeping partCacheKeys: [String]) throws -> Int {
        try database.writer.write { db in
            let wanted = Set(partCacheKeys)
            let stale = try DownloadRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .fetchAll(db)
                .filter { !wanted.contains($0.partCacheKey) }

            for record in stale { try record.delete(db) }
            return stale.count
        }
    }

    public func allRelativePaths() throws -> Set<String> {
        try database.writer.read { db in
            Set(try DownloadRecord.fetchAll(db).compactMap(\.relativePath))
        }
    }

    public func downloadedBooks() throws -> [(bookRatingKey: String, bytes: Int)] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT book_rating_key, SUM(bytes_done) AS bytes
                FROM download WHERE state = ?
                GROUP BY book_rating_key
                ORDER BY bytes DESC
                """, arguments: [DownloadRecord.State.complete.rawValue])
            .map { (bookRatingKey: $0["book_rating_key"], bytes: $0["bytes"] ?? 0) }
        }
    }

    public func totalBytes() throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(bytes_done), 0) FROM download WHERE state = ?
                """, arguments: [DownloadRecord.State.complete.rawValue]) ?? 0
        }
    }

    /// Forgets a book's downloads and reports the files to delete.
    ///
    /// The rows go here; the files are the platform's business. Returning the
    /// paths rather than deleting them keeps this free of `FileManager`, which
    /// is what lets it live in Core.
    public func evict(bookRatingKey: String) throws -> [String] {
        try database.writer.write { db in
            let records = try DownloadRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .fetchAll(db)
            try DownloadRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .deleteAll(db)
            return records.compactMap(\.relativePath)
        }
    }

    /// Books finished listening to and still taking up space.
    /// Forgets every download, and says which files to delete.
    ///
    /// The rows and the files are two different things: this owns the rows, and
    /// the caller owns the bytes on disk. Returning the paths rather than
    /// deleting them keeps it that way — this type has never touched the file
    /// system and should not start.
    public func evictAll() throws -> [String] {
        try database.writer.write { db in
            let paths = try DownloadRecord.fetchAll(db).compactMap(\.relativePath)
            try DownloadRecord.deleteAll(db)
            return paths
        }
    }

    public func evictableFinished() throws -> [String] {
        try database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT download.book_rating_key
                FROM download
                JOIN progress ON progress.book_rating_key = download.book_rating_key
                WHERE download.state = ? AND progress.finished_at IS NOT NULL
                """, arguments: [DownloadRecord.State.complete.rawValue])
        }
    }
}

public enum BookDownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(fraction: Double)
    case complete(bytes: Int)
    case failed(String)

    public var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    public var isActive: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// Whether this state can still change on its own.
    ///
    /// A download in flight becomes something else without anybody touching it;
    /// the other three only change when somebody acts. Views use this to decide
    /// whether it is worth watching — a poll that runs while nothing is
    /// happening is a poll that will be removed by whoever notices it.
    public var isSettled: Bool { !isActive }
}
