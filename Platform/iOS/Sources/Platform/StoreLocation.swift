import Foundation
import Audiobooks

/// Where the database lives on this platform.
///
/// Application Support, excluded from backup. The database is authoritative
/// here — losing it loses bookmarks and session history that exist nowhere on
/// the Plex server.
public enum StoreLocation {
    public static func databaseURL(named name: String = "vocalisbook.sqlite") throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("VocalisBook", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    public static func open() throws -> AudiobookDatabase {
        try AudiobookDatabase.open(at: databaseURL(), durability: .durable)
    }
}
