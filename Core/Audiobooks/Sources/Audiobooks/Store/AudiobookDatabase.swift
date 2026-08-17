import Foundation
import GRDB

/// Owns the SQLite connection.
///
/// The durability contract differs by platform and is passed in rather than
/// detected, so the caller has to state it. On iOS and macOS this database is
/// authoritative; on tvOS it is a cache that may vanish between launches and
/// everything read from it must be recoverable from Plex plus CloudKit.
public final class AudiobookDatabase: Sendable {

    public enum Durability: Sendable {
        /// Application Support, excluded from backup, survives relaunch.
        case durable
        /// Caches, purgeable by the system at any time. tvOS only.
        case ephemeral
    }

    public let writer: any DatabaseWriter
    public let durability: Durability

    private init(writer: any DatabaseWriter, durability: Durability) {
        self.writer = writer
        self.durability = durability
    }

    public static func open(at url: URL, durability: Durability) throws -> AudiobookDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // Metadata sync writes in bulk while the UI reads; a busy timeout is
        // cheaper than surfacing SQLITE_BUSY to a view model.
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let pool = try DatabasePool(path: url.path, configuration: config)
        let database = AudiobookDatabase(writer: pool, durability: durability)
        try database.migrate()

        if durability == .durable {
            try? database.excludeFromBackup(url)
        }
        return database
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AudiobookDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        let database = AudiobookDatabase(writer: queue, durability: .durable)
        try database.migrate()
        return database
    }

    private func migrate() throws {
        try Schema.migrator().migrate(writer)
    }

    /// A 40 GB audiobook library must never enter iCloud Backup, and neither
    /// should the database that indexes it.
    private func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    /// Drops all cached Plex metadata but keeps user data.
    ///
    /// Used when switching servers or libraries. Progress, bookmarks and
    /// sessions survive deliberately: a book's rating key is stable across a
    /// library rescan, so someone's place should not be lost because the
    /// metadata cache was rebuilt.
    /// Everything this device has cached, so it can be built again from scratch.
    ///
    /// The library and the listening state both go: the library comes back from
    /// Plex and the listening state from iCloud, and this exists for when
    /// something local has gone wrong badly enough that the shortest way out is
    /// to have neither.
    ///
    /// The *section* stays, and so does the server. Deleting those would sign
    /// the device out and make somebody pick their library again, which is not
    /// what "reload everything" means — the books cascade from the section, so
    /// keeping the row costs nothing and saves a sign-in.
    ///
    /// Download rows go here; the files on disk are the caller's to remove,
    /// because this type has never touched the file system.
    public func purgeAllCachedData() throws {
        try writer.write { db in
            // Books cascade to tracks, chapters, genres, series, sequences.
            try db.execute(sql: "DELETE FROM book")
            try db.execute(sql: "DELETE FROM plex_collection")

            try db.execute(sql: "DELETE FROM progress")
            try db.execute(sql: "DELETE FROM bookmark")
            try db.execute(sql: "DELETE FROM book_settings")
            try db.execute(sql: "DELETE FROM listening_session")
            try db.execute(sql: "DELETE FROM outbox")
            try db.execute(sql: "DELETE FROM download")
            try db.execute(sql: "DELETE FROM cloud_progress")

            // So the next refresh is a full one rather than an incremental sync
            // against a stamp describing a library that is no longer here.
            try db.execute(sql: "UPDATE library_section SET last_synced_at = NULL")
        }
    }

    /// Drops the rows iCloud is authoritative for, keeping the library.
    ///
    /// For a deliberate resync: throw away this device's copy of the syncable
    /// state and let the container refill it. The library and its artwork are
    /// Plex's and cost a full re-fetch to rebuild, so they stay.
    ///
    /// The outbox goes with them. Its entries describe positions that no longer
    /// exist here, and pushing one after this would send Plex a place nobody is
    /// any more.
    public func purgeSyncedUserData() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM progress")
            try db.execute(sql: "DELETE FROM bookmark")
            try db.execute(sql: "DELETE FROM book_settings")
            try db.execute(sql: "DELETE FROM listening_session")
            try db.execute(sql: "DELETE FROM outbox")
        }
    }


    public func purgeMetadataCache() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM library_section")
        }
    }
}
