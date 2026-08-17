import Foundation
import GRDB

// Records map camelCase Swift to snake_case SQL via CodingKeys. The extra
// verbosity buys a schema that reads properly in `sqlite3`, which is where
// these get inspected when something looks wrong.

public struct BookRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "book"

    public var ratingKey: String
    public var librarySectionID: String
    public var title: String
    public var titleSort: String?
    public var author: String?
    public var authorRatingKey: String?
    public var narrator: String?
    public var summary: String?
    public var year: Int?
    public var thumb: String?
    public var trackCount: Int?
    public var durationMs: Int?
    public var addedAt: Date?
    public var plexUpdatedAt: Date?
    public var cachedAt: Date

    /// The recording language, when the agent had evidence. Nil is unknown.
    public var language: String?

    /// `Abridged` or `Unabridged`, when known. Nil is unknown, not unabridged.
    public var edition: String?

    /// The canonical cross-server identity, from the agent's GUID.
    ///
    /// Stored beside the rating key rather than replacing it: the rating key is
    /// still how Plex is addressed, and this is what travels between servers.
    public var identityKey: String?

    /// Defaulted, so the several places that build one of these keep compiling.
    /// A book cached before v7 has none of the three, which is what nil means.
    public init(
        ratingKey: String,
        librarySectionID: String,
        title: String,
        titleSort: String? = nil,
        author: String? = nil,
        authorRatingKey: String? = nil,
        narrator: String? = nil,
        summary: String? = nil,
        year: Int? = nil,
        thumb: String? = nil,
        trackCount: Int? = nil,
        durationMs: Int? = nil,
        addedAt: Date? = nil,
        plexUpdatedAt: Date? = nil,
        cachedAt: Date = Date(),
        language: String? = nil,
        edition: String? = nil,
        identityKey: String? = nil
    ) {
        self.ratingKey = ratingKey
        self.librarySectionID = librarySectionID
        self.title = title
        self.titleSort = titleSort
        self.author = author
        self.authorRatingKey = authorRatingKey
        self.narrator = narrator
        self.summary = summary
        self.year = year
        self.thumb = thumb
        self.trackCount = trackCount
        self.durationMs = durationMs
        self.addedAt = addedAt
        self.plexUpdatedAt = plexUpdatedAt
        self.cachedAt = cachedAt
        self.language = language
        self.edition = edition
        self.identityKey = identityKey
    }

    enum CodingKeys: String, CodingKey {
        case ratingKey = "rating_key"
        case librarySectionID = "library_section_id"
        case title
        case titleSort = "title_sort"
        case author
        case authorRatingKey = "author_rating_key"
        case narrator, summary, year, thumb, language, edition
        case trackCount = "track_count"
        case durationMs = "duration_ms"
        case addedAt = "added_at"
        case plexUpdatedAt = "plex_updated_at"
        case cachedAt = "cached_at"
        case identityKey = "identity_key"
    }
}

public struct TrackRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "track"

    public var ratingKey: String
    public var bookRatingKey: String
    public var idx: Int
    public var title: String
    public var durationMs: Int
    public var startMs: Int
    public var plexKey: String
    public var partID: String
    public var partKey: String
    public var partCacheKey: String
    public var container: String?

    enum CodingKeys: String, CodingKey {
        case ratingKey = "rating_key"
        case bookRatingKey = "book_rating_key"
        case idx, title, container
        case durationMs = "duration_ms"
        case startMs = "start_ms"
        case plexKey = "plex_key"
        case partID = "part_id"
        case partKey = "part_key"
        case partCacheKey = "part_cache_key"
    }
}

/// The only record with a database-assigned id, and therefore the only one that
/// conforms to `MutablePersistableRecord` rather than `PersistableRecord`.
///
/// `didInsert` is `mutating` on the mutable protocol and non-mutating on the
/// other, so declaring it here while conforming to `PersistableRecord` does not
/// satisfy the requirement — it silently becomes an unrelated method and the
/// conformance fails. Everything else has a natural key from Plex and needs
/// neither the write-back nor the mutability.
public struct ChapterRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "chapter"

    public var id: Int64?
    public var bookRatingKey: String
    public var idx: Int
    public var title: String
    public var startMs: Int
    public var endMs: Int
    public var source: String

    enum CodingKeys: String, CodingKey {
        case id, idx, title, source
        case bookRatingKey = "book_rating_key"
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ProgressRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "progress"

    public var bookRatingKey: String
    public var absoluteMs: Int
    public var changedAt: Date
    public var syncedOffsetMs: Int?
    public var syncedAt: Date?
    public var finishedAt: Date?
    public var revision: Int
    public var dirty: Bool

    /// Whether iCloud still needs this row.
    ///
    /// Separate from `dirty`, which means "Plex has not taken it yet". The two
    /// destinations acknowledge independently, and neither may clear the other's
    /// flag — whichever pushed first would otherwise mark the row clean and the
    /// other would never see it.
    public var cloudDirty: Bool

    enum CodingKeys: String, CodingKey {
        case bookRatingKey = "book_rating_key"
        case absoluteMs = "absolute_ms"
        case changedAt = "changed_at"
        case syncedOffsetMs = "synced_offset_ms"
        case syncedAt = "synced_at"
        case finishedAt = "finished_at"
        case cloudDirty = "cloud_dirty"
        case revision, dirty
    }

    public init(
        bookRatingKey: String,
        absoluteMs: Int,
        changedAt: Date,
        syncedOffsetMs: Int? = nil,
        syncedAt: Date? = nil,
        finishedAt: Date? = nil,
        revision: Int = 0,
        dirty: Bool = false,
        cloudDirty: Bool = true
    ) {
        self.bookRatingKey = bookRatingKey
        self.absoluteMs = absoluteMs
        self.changedAt = changedAt
        self.syncedOffsetMs = syncedOffsetMs
        self.syncedAt = syncedAt
        self.finishedAt = finishedAt
        self.revision = revision
        self.dirty = dirty
        self.cloudDirty = cloudDirty
    }
}

public struct BookmarkRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "bookmark"

    public var id: String
    public var bookRatingKey: String
    public var absoluteMs: Int
    public var label: String?
    public var createdAt: Date
    public var revision: Int
    public var dirty: Bool
    public var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, label, revision, dirty
        case bookRatingKey = "book_rating_key"
        case absoluteMs = "absolute_ms"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
    }
}

public struct OutboxRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "outbox"

    public var id: String
    public var bookRatingKey: String
    public var kind: String
    public var absoluteMs: Int
    public var recordedAt: Date
    public var revision: Int
    public var attempts: Int
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, revision, attempts
        case bookRatingKey = "book_rating_key"
        case absoluteMs = "absolute_ms"
        case recordedAt = "recorded_at"
        case lastError = "last_error"
    }

    public init(entry: OutboxEntry) {
        self.id = entry.id.uuidString
        self.bookRatingKey = entry.bookRatingKey
        self.kind = entry.kind.rawValue
        self.absoluteMs = entry.absoluteMs
        self.recordedAt = entry.recordedAt
        self.revision = entry.revision
        self.attempts = entry.attempts
        self.lastError = entry.lastError
    }

    public var entry: OutboxEntry? {
        guard let uuid = UUID(uuidString: id),
              let kind = OutboxEntry.Kind(rawValue: kind) else { return nil }
        return OutboxEntry(
            id: uuid,
            bookRatingKey: bookRatingKey,
            kind: kind,
            absoluteMs: absoluteMs,
            recordedAt: recordedAt,
            revision: revision,
            attempts: attempts,
            lastError: lastError
        )
    }
}

public struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "download"

    public enum State: String, Codable, Sendable {
        case queued, downloading, complete, failed
    }

    public var partCacheKey: String
    public var bookRatingKey: String
    public var trackRatingKey: String
    public var state: String
    public var bytesTotal: Int?
    public var bytesDone: Int
    public var relativePath: String?
    public var completedAt: Date?
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case state
        case partCacheKey = "part_cache_key"
        case bookRatingKey = "book_rating_key"
        case trackRatingKey = "track_rating_key"
        case bytesTotal = "bytes_total"
        case bytesDone = "bytes_done"
        case relativePath = "relative_path"
        case completedAt = "completed_at"
        case lastError = "last_error"
    }
}

public struct LibrarySectionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "library_section"

    public var id: String
    public var serverID: String
    public var sectionKey: String
    public var title: String
    public var lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title
        case serverID = "server_id"
        case sectionKey = "section_key"
        case lastSyncedAt = "last_synced_at"
    }
}

public struct ServerRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "server"

    public var machineIdentifier: String
    public var name: String
    public var lastConnectedURI: String?
    public var lastConnectedAt: Date?
    public var lastConnectionWasRelay: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case machineIdentifier = "machine_identifier"
        case lastConnectedURI = "last_connected_uri"
        case lastConnectedAt = "last_connected_at"
        case lastConnectionWasRelay = "last_connection_was_relay"
    }
}

public struct PlexCollectionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable, Identifiable {
    public static let databaseTableName = "plex_collection"

    /// The rating key. `PlexCollection` was `Identifiable` and this replaced it
    /// in the views without carrying that over, so a bare `ForEach` over these
    /// stopped compiling.
    public var id: String { ratingKey }

    public var ratingKey: String
    public var librarySectionID: String
    public var title: String
    public var titleSort: String?
    public var childCount: Int?
    public var thumb: String?
    public var summary: String?
    public var cachedAt: Date

    enum CodingKeys: String, CodingKey {
        case title, thumb, summary
        case ratingKey = "rating_key"
        case librarySectionID = "library_section_id"
        case titleSort = "title_sort"
        case childCount = "child_count"
        case cachedAt = "cached_at"
    }
}

public struct PlexCollectionItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "plex_collection_item"

    public var collectionRatingKey: String
    public var bookRatingKey: String
    public var position: Int

    enum CodingKeys: String, CodingKey {
        case position
        case collectionRatingKey = "collection_rating_key"
        case bookRatingKey = "book_rating_key"
    }
}
