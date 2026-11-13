import Foundation
import GRDB

/// Separates retained listening data from Plex's reusable database row numbers.
/// Detached keys never join a cached book. Only a matching identity claims them.
enum LocalBookState {
    static let prefix = "@identity:"
    static let tables = ["progress", "book_settings", "bookmark", "listening_session", "outbox"]

    static func detachAll(_ db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT rating_key, identity_key FROM book") {
            let key: String = row["rating_key"]
            let identity: String? = row["identity_key"]
            try move(from: key, to: identity.map { prefix + $0 } ?? "@unresolved:\(key)", db: db)
        }
    }

    static func prepare(bookKey: String, identity: String, sectionID: String, db: Database) throws {
        let old = try Row.fetchOne(db, sql: "SELECT identity_key, library_section_id FROM book WHERE rating_key = ?", arguments: [bookKey])
        let oldIdentity: String? = old?["identity_key"]
        let server = sectionID.split(separator: ":").first.map(String.init) ?? sectionID
        let fallback = "plex:\(server):\(bookKey)"
        // A same-server fallback gaining a provider GUID is a metadata upgrade.
        if let oldIdentity, oldIdentity != identity,
           !(oldIdentity == fallback && (old?["library_section_id"] as String?) == sectionID) {
            try move(from: bookKey, to: prefix + oldIdentity, db: db)
            try db.execute(sql: "DELETE FROM book WHERE rating_key = ?", arguments: [bookKey])
        }
        for source in Set([prefix + identity, prefix + fallback]) {
            try move(from: source, to: bookKey, db: db)
        }
        try db.execute(sql: "UPDATE listening_session SET library_section_id = ? WHERE book_rating_key = ?",
                       arguments: [sectionID, bookKey])
    }

    /// Unattributable legacy rows are retained for recovery, never guessed onto
    /// a new server. This only runs once, during the upgrade from v13.
    static func quarantineOrphans(_ db: Database) throws {
        for table in tables {
            let keys = try String.fetchAll(db, sql: "SELECT DISTINCT book_rating_key FROM \(table) WHERE book_rating_key NOT IN (SELECT rating_key FROM book)")
            for key in keys where !key.hasPrefix("@") {
                try db.execute(sql: "UPDATE \(table) SET book_rating_key = ? WHERE book_rating_key = ?",
                               arguments: ["@unresolved:\(key)", key])
            }
        }
    }

    private static func move(from source: String, to target: String, db: Database) throws {
        guard source != target else { return }
        for (table, order) in [("progress", "changed_at"), ("book_settings", "revision")] {
            if let sourceRow = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE book_rating_key = ?", arguments: [source]) {
                let targetRow = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE book_rating_key = ?", arguments: [target])
                let keepSource: Bool
                if let targetRow {
                    if table == "progress" {
                        let a: Date = sourceRow[order], b: Date = targetRow[order]
                        keepSource = a > b || (a == b && (sourceRow["revision"] as Int) > (targetRow["revision"] as Int))
                    } else { keepSource = (sourceRow[order] as Int) > (targetRow[order] as Int) }
                } else { keepSource = true }
                try db.execute(sql: "DELETE FROM \(table) WHERE book_rating_key = ?", arguments: [keepSource ? target : source])
                if keepSource {
                    try db.execute(sql: "UPDATE \(table) SET book_rating_key = ? WHERE book_rating_key = ?", arguments: [target, source])
                    if table == "progress" {
                        try db.execute(sql: "UPDATE progress SET synced_at = NULL, synced_offset_ms = NULL WHERE book_rating_key = ?", arguments: [target])
                    }
                }
            }
        }
        for table in ["bookmark", "listening_session"] {
            try db.execute(sql: "UPDATE \(table) SET book_rating_key = ? WHERE book_rating_key = ?", arguments: [target, source])
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM outbox WHERE book_rating_key = ?", arguments: [source]) {
            let kind: String = row["kind"], id: String = row["id"]
            let other = try Row.fetchOne(db, sql: "SELECT id, recorded_at FROM outbox WHERE book_rating_key = ? AND kind = ?", arguments: [target, kind])
            if let other, (other["recorded_at"] as Date) >= (row["recorded_at"] as Date) {
                try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id])
            } else {
                if let other { try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [other["id"] as String]) }
                try db.execute(sql: "UPDATE outbox SET book_rating_key = ? WHERE id = ?", arguments: [target, id])
            }
        }
    }
}
