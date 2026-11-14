import Foundation
import GRDB

/// Portable listening data only: no account tokens, downloads or database files.
public struct ListeningBackup: Codable, Sendable {
    public var format = "VocalisBookListeningBackup"
    public var version = 1
    public var createdAt: Date
    public var books: [Book]

    public struct Book: Codable, Sendable {
        public var identity: String
        public var progress: ProgressRecord?
        public var bookmarks: [BookmarkRecord] = []
        public var settings: Settings?
        public var sessions: [Session] = []
        public var pendingActions: [OutboxEntry.Kind] = []
    }
    public struct Settings: Codable, Sendable {
        public var rate: Double?
        public var revision: Int
    }
    public struct Session: Codable, Sendable {
        public var id: String
        public var startedAt: Date
        public var endedAt: Date?
        public var startMs: Int
        public var endMs: Int?
        public var rate: Double?
        public var revision: Int
        public var originDeviceID: String
        public var lastListenedAt: Date?
        public var lastListenedMs: Int?
    }
    public var summary: String {
        let bookmarks = books.reduce(0) { $0 + $1.bookmarks.count }
        let sessions = books.reduce(0) { $0 + $1.sessions.count }
        return "\(books.count) book records, \(bookmarks) bookmarks and \(sessions) listening sessions"
    }
}

public enum ListeningBackupError: LocalizedError {
    case invalid, unsupportedVersion, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid VocalisBook listening backup. Nothing was imported."
        case .unsupportedVersion: "This backup needs a newer version of VocalisBook. Nothing was imported."
        case .tooLarge: "This backup exceeds the supported size of 50 MB. Nothing was imported."
        }
    }
}

public struct ListeningBackupStore: Sendable {
    public static let maximumBytes = 50 * 1024 * 1024
    private let database: AudiobookDatabase
    public init(database: AudiobookDatabase) { self.database = database }

    public func export(now: Date = Date()) throws -> Data {
        let backup = try database.writer.read { db in try Self.snapshot(db, now: now) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(backup)
        _ = try Self.inspect(data)
        return data
    }

    static func snapshot(_ db: Database, now: Date) throws -> ListeningBackup {
        let keys = try String.fetchAll(db, sql: """
            SELECT book_rating_key FROM progress UNION SELECT book_rating_key FROM bookmark
            UNION SELECT book_rating_key FROM book_settings UNION SELECT book_rating_key FROM listening_session
            """)
        let device = try String.fetchOne(db, sql: "SELECT identifier FROM local_device WHERE singleton = 1") ?? "legacy"
        var books = try keys.map { key -> ListeningBackup.Book in
            let identity = try CloudSyncStore.identity(forBook: key, db: db) ?? "unresolved:\(device):\(key)"
            let settings = try Row.fetchOne(db, sql: "SELECT * FROM book_settings WHERE book_rating_key = ?", arguments: [key])
            let sessions = try Row.fetchAll(db, sql: "SELECT * FROM listening_session WHERE book_rating_key = ? ORDER BY id", arguments: [key])
            return ListeningBackup.Book(identity: identity,
                progress: try ProgressRecord.fetchOne(db, key: key),
                bookmarks: try BookmarkRecord.filter(Column("book_rating_key") == key).order(Column("id")).fetchAll(db),
                settings: settings.map { .init(rate: $0["rate"], revision: $0["revision"]) },
                sessions: sessions.map(Self.session),
                pendingActions: try OutboxRecord.filter(Column("book_rating_key") == key).fetchAll(db)
                    .compactMap { OutboxEntry.Kind(rawValue: $0.kind) })
        }
        // Inbox data is listening data too, including records whose book is
        // not cached. Convert it to identity-owned rows for durable restore.
        for row in try Row.fetchAll(db, sql: "SELECT * FROM cloud_progress ORDER BY identity_key") {
            books.append(try Self.book(from: CloudSyncStore.progressRecord(from: row)))
        }
        for data in try Data.fetchAll(db, sql: "SELECT payload FROM cloud_pending_record ORDER BY record_name") {
            books.append(try Self.book(from: JSONDecoder().decode(CloudRecord.self, from: data)))
        }
        return ListeningBackup(createdAt: now, books: books)
    }

    public static func inspect(_ data: Data) throws -> ListeningBackup {
        guard data.count <= maximumBytes else { throw ListeningBackupError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let backup: ListeningBackup
        do { backup = try decoder.decode(ListeningBackup.self, from: data) }
        catch { throw ListeningBackupError.invalid }
        guard backup.format == "VocalisBookListeningBackup" else { throw ListeningBackupError.invalid }
        guard backup.version == 1 else { throw ListeningBackupError.unsupportedVersion }
        guard valid(backup.createdAt), backup.books.count <= 100_000 else { throw ListeningBackupError.invalid }
        var count = 0
        for book in backup.books {
            count += 1 + book.bookmarks.count + book.sessions.count
            guard count <= 100_000, (["spokenmeta:", "plex:", "unresolved:"].contains { book.identity.hasPrefix($0) }), book.identity.utf8.count <= 4096 else { throw ListeningBackupError.invalid }
            if let p = book.progress {
                guard (0...3_155_760_000_000).contains(p.absoluteMs), (0...1_000_000_000).contains(p.revision), valid(p.changedAt), p.finishedAt.map(valid) ?? true else { throw ListeningBackupError.invalid }
            }
            if let settings = book.settings {
                guard (0...1_000_000_000).contains(settings.revision), settings.rate.map({ $0.isFinite && $0 > 0 && $0 <= 10 }) ?? true else { throw ListeningBackupError.invalid }
            }
            for bookmark in book.bookmarks {
                guard !bookmark.id.isEmpty, bookmark.id.utf8.count <= 512, (0...1_000_000_000).contains(bookmark.revision),
                      (0...3_155_760_000_000).contains(bookmark.absoluteMs), valid(bookmark.createdAt), bookmark.deletedAt.map(valid) ?? true,
                      (bookmark.label?.utf8.count ?? 0) <= 65_536 else { throw ListeningBackupError.invalid }
            }
            for session in book.sessions {
                guard !session.id.isEmpty, session.id.utf8.count <= 512, (0...1_000_000_000).contains(session.revision),
                      valid(session.startedAt), session.endedAt.map(valid) ?? true,
                      session.lastListenedAt.map(valid) ?? true, session.startMs >= 0,
                      session.rate.map({ $0.isFinite && $0 > 0 && $0 <= 10 }) ?? true else { throw ListeningBackupError.invalid }
            }
        }
        return backup
    }

    /// A transaction merges rather than replacing data. Newer local revisions
    /// win; accepted imports become dirty and reach the normal sync pipelines.
    @discardableResult
    public func restore(_ data: Data) throws -> Int {
        let backup = try Self.inspect(data)
        return try database.writer.write { db in try Self.merge(backup, db: db) }
    }

    static func merge(_ backup: ListeningBackup, db: Database) throws -> Int {
        var restored = 0
        for book in backup.books {
            let resolved = try CloudSyncStore.localBook(for: book.identity, db: db)
            let key = resolved ?? LocalBookState.prefix + book.identity
            if var progress = book.progress {
                let local = try ProgressRecord.fetchOne(db, key: key)
                if local == nil || progress.changedAt > local!.changedAt ||
                    (progress.changedAt == local!.changedAt && progress.revision > local!.revision) {
                    progress.bookRatingKey = key
                    progress.revision = max(progress.revision, local?.revision ?? 0) + 1
                    progress.dirty = true; progress.cloudDirty = true
                    progress.syncedAt = nil; progress.syncedOffsetMs = nil
                    try progress.save(db)
                    try SyncStore.enqueue(db, bookRatingKey: key, kind: .position,
                        absoluteMs: progress.absoluteMs, at: progress.changedAt, revision: progress.revision)
                    if progress.finishedAt != nil || local?.finishedAt != nil || book.pendingActions.contains(.unfinished) {
                        try SyncStore.enqueue(db, bookRatingKey: key, kind: progress.finishedAt == nil ? .unfinished : .finished,
                            absoluteMs: progress.absoluteMs, at: progress.changedAt, revision: progress.revision)
                    }
                    restored += 1
                }
            }
            for var bookmark in book.bookmarks {
                let local = try BookmarkRecord.fetchOne(db, key: bookmark.id)
                guard local == nil || bookmark.revision > local!.revision else { continue }
                if let local, try CloudSyncStore.identity(forBook: local.bookRatingKey, db: db) != book.identity { continue }
                bookmark.bookRatingKey = key
                bookmark.revision += 1; bookmark.dirty = true
                try bookmark.save(db)
                restored += 1
            }
            if let settings = book.settings {
                let revision = try Int.fetchOne(db, sql: "SELECT revision FROM book_settings WHERE book_rating_key = ?", arguments: [key])
                if revision == nil || settings.revision > revision! {
                    try db.execute(sql: """
                        INSERT INTO book_settings (book_rating_key, rate, revision, dirty) VALUES (?, ?, ?, 1)
                        ON CONFLICT(book_rating_key) DO UPDATE SET rate = excluded.rate, revision = excluded.revision, dirty = 1
                        """, arguments: [key, settings.rate, settings.revision + 1])
                    restored += 1
                }
            }
            for session in book.sessions {
                let existing = try Row.fetchOne(db, sql: "SELECT revision, book_rating_key FROM listening_session WHERE id = ?", arguments: [session.id])
                let revision: Int? = existing?["revision"]
                guard revision == nil || session.revision > revision! else { continue }
                if let oldKey = existing?["book_rating_key"] as String?,
                   try CloudSyncStore.identity(forBook: oldKey, db: db) != book.identity { continue }
                let recovered = min(session.lastListenedAt ?? session.startedAt, backup.createdAt)
                let endedAt = session.endedAt ?? max(session.startedAt, recovered)
                let endMs = session.endedAt == nil ? (session.lastListenedMs ?? session.startMs) : session.endMs
                let section = try String.fetchOne(db, sql: "SELECT library_section_id FROM book WHERE rating_key = ?", arguments: [key])
                let owner = session.originDeviceID.hasPrefix("restored:") ? session.originDeviceID : "restored:" + session.originDeviceID
                try db.execute(sql: """
                    INSERT INTO listening_session (id, book_rating_key, started_at, ended_at, start_ms, end_ms, rate,
                        revision, dirty, library_section_id, origin_device_id, last_listened_at, last_listened_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET book_rating_key = excluded.book_rating_key,
                        started_at = excluded.started_at, ended_at = excluded.ended_at, start_ms = excluded.start_ms,
                        end_ms = excluded.end_ms, rate = excluded.rate, revision = excluded.revision, dirty = 1,
                        library_section_id = excluded.library_section_id, origin_device_id = excluded.origin_device_id,
                        last_listened_at = excluded.last_listened_at, last_listened_ms = excluded.last_listened_ms
                    """, arguments: [session.id, key, session.startedAt, endedAt, session.startMs, endMs, session.rate,
                                      session.revision + 1, section, owner, session.lastListenedAt, session.lastListenedMs])
                restored += 1
            }
        }
        return restored
    }

    private static func valid(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && abs(date.timeIntervalSince1970) < 100_000_000_000
    }

    private static func session(_ row: Row) -> ListeningBackup.Session {
        .init(id: row["id"], startedAt: row["started_at"], endedAt: row["ended_at"], startMs: row["start_ms"],
              endMs: row["end_ms"], rate: row["rate"], revision: row["revision"], originDeviceID: row["origin_device_id"],
              lastListenedAt: row["last_listened_at"], lastListenedMs: row["last_listened_ms"])
    }

    private static func book(from record: CloudRecord) throws -> ListeningBackup.Book {
        guard let identity = record.kind == .progress ? record.id : record.fields["bookIdentity"]?.stringValue,
              !identity.isEmpty else { throw ListeningBackupError.invalid }
        var book = ListeningBackup.Book(identity: identity)
        switch record.kind {
        case .progress:
            guard let offset = record.fields["absoluteMs"]?.intValue, let changed = record.fields["changedAt"]?.dateValue else { throw ListeningBackupError.invalid }
            book.progress = ProgressRecord(bookRatingKey: "", absoluteMs: offset, changedAt: changed,
                finishedAt: record.fields["finishedAt"]?.dateValue, revision: record.revision)
        case .bookmark:
            let date = record.fields["createdAt"]?.dateValue ?? record.fields["deletedAt"]?.dateValue ?? .distantPast
            let offset = record.fields["absoluteMs"]?.intValue ?? 0
            book.bookmarks = [BookmarkRecord(id: record.id, bookRatingKey: "", absoluteMs: offset,
                label: record.fields["label"]?.stringValue, createdAt: date, revision: record.revision,
                dirty: false, deletedAt: record.isDeleted ? record.fields["deletedAt"]?.dateValue ?? date : nil)]
        case .bookSettings:
            book.settings = .init(rate: record.fields["rate"]?.doubleValue, revision: record.revision)
        case .listeningSession:
            guard let start = record.fields["startedAt"]?.dateValue else { throw ListeningBackupError.invalid }
            book.sessions = [.init(id: record.id, startedAt: start, endedAt: record.fields["endedAt"]?.dateValue,
                startMs: record.fields["startMs"]?.intValue ?? 0, endMs: record.fields["endMs"]?.intValue,
                rate: record.fields["rate"]?.doubleValue, revision: record.revision,
                originDeviceID: record.fields["originDeviceID"]?.stringValue ?? "legacy-remote",
                lastListenedAt: record.fields["lastListenedAt"]?.dateValue, lastListenedMs: record.fields["lastListenedMs"]?.intValue)]
        }
        return book
    }
}
