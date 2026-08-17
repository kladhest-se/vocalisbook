import Foundation
import Audiobooks

/// Where the database lives on tvOS.
///
/// There is deliberately no `DownloadCoordinator` in this repo, and this store
/// is a cache rather than a home for user data — see
/// `PlatformCapabilities.supportsOfflineDownloads` and `.localStoreIsDurable`.
public enum EphemeralStore {
    /// tvOS permits writes only to Caches, and the system may empty it at any
    /// time including between launches. Treat every read as a miss that must be
    /// recoverable from Plex plus CloudKit.
    public static func databaseURL(named name: String = "library-cache.sqlite") throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches.appendingPathComponent("VocalisBook", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    /// Opens the cache, rebuilding it from scratch if it is missing or
    /// unreadable.
    ///
    /// A corrupt or absent database is an ordinary event on this platform, not
    /// an error to report. Deleting and reopening is always correct here
    /// precisely because nothing authoritative is stored in it — which is not
    /// true on iOS or macOS, where the same recovery would silently destroy
    /// bookmarks and session history.
    public static func open() throws -> AudiobookDatabase {
        let url = try databaseURL()
        do {
            return try AudiobookDatabase.open(at: url, durability: .ephemeral)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return try AudiobookDatabase.open(at: url, durability: .ephemeral)
        }
    }
}
