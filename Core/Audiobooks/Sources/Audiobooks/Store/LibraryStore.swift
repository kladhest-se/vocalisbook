import Foundation
import GRDB
import PlexKit

/// Reads and writes the cached Plex metadata.
///
/// Everything here is a mirror of the server and is safe to drop. It exists so
/// the library is browsable with no network and so scrolling a few thousand
/// books does not hit Plex.
public struct LibraryStore: Sendable {
    private let database: AudiobookDatabase

    public init(database: AudiobookDatabase) {
        self.database = database
    }

    // MARK: - Writing the cache

    /// Replaces the cached tracks and chapters for one book, and stores the
    /// book's real duration.
    ///
    /// Track rows carry a denormalised `start_ms` so a timeline can be rebuilt
    /// with one ordered query rather than a running sum in Swift on every load.
    /// That means this is the only place absolute offsets are computed, and the
    /// only place that can get them wrong.
    /// Records that a book is in a series.
    ///
    /// Additive, unlike `replaceTags`. That one clears a book's rows before
    /// writing because it has the book's whole list in hand; this arrives one
    /// tag at a time from Plex's tag directory and has no idea what else the
    /// book belongs to. Clearing here would mean each series erased the last.
    ///
    /// Ignored when the book is not cached: a tag can name a book this device
    /// has not fetched, and a row pointing at nothing would fail the foreign key
    /// anyway.
    public func addSeries(_ name: String, toBook bookRatingKey: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO book_series (book_rating_key, name)
                    SELECT ?, ? WHERE EXISTS (SELECT 1 FROM book WHERE rating_key = ?)
                    """,
                arguments: [bookRatingKey, name, bookRatingKey]
            )
        }
    }

    /// Records where a book sits in a series.
    ///
    /// `REPLACE` rather than `IGNORE`: a book has one position per series, and a
    /// re-scan after the agent corrected it should land the correction.
    public func addSequence(_ sequence: BookSequence, toBook bookRatingKey: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO book_sequence (book_rating_key, series, position)
                    SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM book WHERE rating_key = ?)
                    """,
                arguments: [bookRatingKey, sequence.series, sequence.position, bookRatingKey]
            )
        }
    }

    /// Claims any position that arrived before this book did.
    ///
    /// The other half of the cloud inbox. A record for a book this device had
    /// not cached was held under its identity; caching the book is the moment it
    /// can be written, and the row leaves the inbox as it goes.
    ///
    /// Only when nothing here is newer. A book cached long after somebody
    /// listened on it locally should not have its place rolled back by a held
    /// record from before that.
    private static func claimHeldProgress(
        _ db: Database,
        bookRatingKey: String,
        identityKey: String
    ) throws {
        guard let held = try Row.fetchOne(
            db,
            sql: """
                SELECT absolute_ms, changed_at, finished_at, revision
                FROM cloud_progress WHERE identity_key = ?
                """,
            arguments: [identityKey]
        ) else { return }

        let changedAt = held["changed_at"] as Date? ?? Date.distantPast

        let existing = try Row.fetchOne(
            db,
            sql: "SELECT changed_at FROM progress WHERE book_rating_key = ?",
            arguments: [bookRatingKey]
        )
        let localIsNewer = (existing?["changed_at"] as Date?).map { $0 > changedAt } ?? false

        if !localIsNewer {
            try db.execute(sql: """
                INSERT INTO progress
                    (book_rating_key, absolute_ms, changed_at, finished_at,
                     revision, dirty, cloud_dirty)
                VALUES (?, ?, ?, ?, ?, 1, 0)
                ON CONFLICT(book_rating_key) DO UPDATE SET
                    absolute_ms = excluded.absolute_ms,
                    changed_at = excluded.changed_at,
                    finished_at = excluded.finished_at,
                    revision = excluded.revision,
                    dirty = 1,
                    cloud_dirty = 0
                """, arguments: [
                    bookRatingKey,
                    held["absolute_ms"] as Int? ?? 0,
                    changedAt,
                    held["finished_at"] as Date?,
                    held["revision"] as Int? ?? 0,
                ])
        }

        // Gone either way. It has been considered, and keeping it would mean
        // reconsidering it on every refresh for ever.
        try db.execute(
            sql: "DELETE FROM cloud_progress WHERE identity_key = ?",
            arguments: [identityKey]
        )
    }

    /// The canonical identity for a book, as a string to store.
    ///
    /// The server's machine identifier is the first component of a section id —
    /// `srv:2` — so the fallback can be built without threading it through every
    /// caller. If that ever stops being true, this is the one place that
    /// assumes it.
    private static func identityKey(for book: PlexBook, sectionID: String) -> String {
        let serverIdentifier = sectionID.split(separator: ":").first.map(String.init) ?? sectionID
        return BookIdentity.from(
            guid: book.guid,
            serverIdentifier: serverIdentifier,
            ratingKey: book.ratingKey
        ).key
    }

    /// The same rule as `replaceTags`, for a table with two values per row.
    private static func replaceSequences(
        _ db: Database,
        bookRatingKey: String,
        values: [BookSequence]
    ) throws {
        guard !values.isEmpty else { return }

        try db.execute(
            sql: "DELETE FROM book_sequence WHERE book_rating_key = ?",
            arguments: [bookRatingKey]
        )
        for sequence in values {
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO book_sequence
                        (book_rating_key, series, position)
                    VALUES (?, ?, ?)
                    """,
                arguments: [bookRatingKey, sequence.series, sequence.position]
            )
        }
    }

    /// Replaces one book's rows in one tag table.
    ///
    /// Only when the response carried tags. The list endpoint omits them and the
    /// detail endpoint includes them, so an empty array usually means "not
    /// asked" rather than "none" — treating the two alike would empty the table
    /// on every library refresh.
    ///
    /// Written once rather than four times. Genres had this logic inline in two
    /// places already; narrators, authors and series would have made eight
    /// copies of a rule that has to stay identical in all of them.
    private static func replaceTags(
        _ db: Database,
        table: String,
        bookRatingKey: String,
        values: [String]
    ) throws {
        guard !values.isEmpty else { return }

        try db.execute(
            sql: "DELETE FROM \(table) WHERE book_rating_key = ?",
            arguments: [bookRatingKey]
        )
        for value in Set(values) {
            try db.execute(
                sql: "INSERT INTO \(table) (book_rating_key, name) VALUES (?, ?)",
                arguments: [bookRatingKey, value]
            )
        }
    }

    public func cache(
        book: PlexBook,
        tracks: [PlexTrack],
        chapters: [Chapter],
        sectionID: String,
        now: Date = Date()
    ) throws {
        let timeline = BookTimeline(
            bookRatingKey: book.ratingKey,
            tracks: tracks,
            chapters: chapters
        )

        try database.writer.write { db in
            let record = BookRecord(
                ratingKey: book.ratingKey,
                librarySectionID: sectionID,
                title: book.title,
                titleSort: book.titleSort ?? book.title,
                author: Self.displayAuthor(for: book),
                authorRatingKey: book.authorRatingKey,
                narrator: nil,
                summary: book.summary,
                year: book.year,
                thumb: book.thumb,
                trackCount: timeline.segments.count,
                // Summed from the tracks. The album-level value Plex reports is
                // frequently absent or wrong and is deliberately ignored.
                durationMs: timeline.totalDurationMs,
                addedAt: book.addedAt,
                plexUpdatedAt: book.updatedAt,
                cachedAt: now,
                language: book.language,
                edition: book.edition,
                identityKey: Self.identityKey(for: book, sectionID: sectionID)
            )
            try record.save(db)

            // Replaced rather than added to.
            //
            // A refresh caches every book again, so inserting would either
            // collide on the primary key or, without one, grow a row per
            // refresh. Deleting first also means a genre removed on the server
            // disappears here, which an upsert alone would never notice.
            //
            // Only when the response carried tags: the list endpoint omits them
            // and the detail endpoint includes them, so an empty array usually
            // means "not asked" rather than "none", and treating the two alike
            // would empty the table on every library refresh.
            try Self.replaceTags(db, table: "book_genre",
                                 bookRatingKey: book.ratingKey, values: book.genres)
            try Self.replaceTags(db, table: "book_narrator",
                                 bookRatingKey: book.ratingKey, values: book.narrators)
            try Self.replaceTags(db, table: "book_author",
                                 bookRatingKey: book.ratingKey, values: book.authors)
            try Self.replaceTags(db, table: "book_series",
                                 bookRatingKey: book.ratingKey, values: book.series)
            try Self.replaceSequences(db, bookRatingKey: book.ratingKey, values: book.sequences)
            try Self.claimHeldProgress(
                db,
                bookRatingKey: book.ratingKey,
                identityKey: Self.identityKey(for: book, sectionID: sectionID)
            )

            try TrackRecord
                .filter(Column("book_rating_key") == book.ratingKey)
                .deleteAll(db)
            for (index, segment) in timeline.segments.enumerated() {
                let track = TrackRecord(
                    ratingKey: segment.trackRatingKey,
                    bookRatingKey: book.ratingKey,
                    // Dense zero-based ordering, not Plex's tag index. Badly
                    // tagged libraries have sparse or duplicated track numbers,
                    // and the timeline's order is what matters here.
                    idx: index,
                    title: segment.title,
                    durationMs: segment.durationMs,
                    startMs: segment.startMs,
                    plexKey: segment.trackKey,
                    partID: segment.partID,
                    partKey: segment.partKey,
                    partCacheKey: segment.partCacheKey,
                    container: nil
                )
                try track.insert(db)
            }

            try ChapterRecord
                .filter(Column("book_rating_key") == book.ratingKey)
                .deleteAll(db)
            for chapter in timeline.chapters {
                var record = ChapterRecord(
                    id: nil,
                    bookRatingKey: book.ratingKey,
                    idx: chapter.index,
                    title: chapter.title,
                    startMs: chapter.startMs,
                    endMs: chapter.endMs,
                    source: chapter.source.rawValue
                )
                try record.insert(db)
            }
        }
    }

    /// Replaces only the chapter rows for one book.
    ///
    /// Deliberately not `cache(book:tracks:chapters:)` with a different chapter
    /// list. That method recomputes every track's denormalised `start_ms`, and
    /// it is documented as the only place absolute offsets are computed. A
    /// chapter upgrade has no `PlexBook` and no fresh tracks in hand, so routing
    /// it through there would mean either inventing them or rewriting offsets
    /// from stale input — and positions already stored against those offsets
    /// would quietly stop meaning what they meant.
    ///
    /// Chapters are derived data keyed on the book alone, so replacing them in
    /// isolation is safe in a way that replacing tracks would not be.
    public func replaceChapters(bookRatingKey: String, chapters: [Chapter]) throws {
        try database.writer.write { db in
            try ChapterRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .deleteAll(db)
            for chapter in chapters {
                var record = ChapterRecord(
                    id: nil,
                    bookRatingKey: bookRatingKey,
                    idx: chapter.index,
                    title: chapter.title,
                    startMs: chapter.startMs,
                    endMs: chapter.endMs,
                    source: chapter.source.rawValue
                )
                try record.insert(db)
            }
        }
    }

    /// Upserts a page of books without touching their tracks.    ///
    /// Listing a section returns album rows only, so a book that is already
    /// cached with tracks must not have its `duration_ms` or `track_count`
    /// clobbered back to nil by a list refresh.
    public func cacheBookList(
        _ books: [PlexBook],
        sectionID: String,
        now: Date = Date()
    ) throws {
        try database.writer.write { db in
            for book in books {
                let existing = try BookRecord.fetchOne(db, key: book.ratingKey)
                let record = BookRecord(
                    ratingKey: book.ratingKey,
                    librarySectionID: sectionID,
                    title: book.title,
                    titleSort: book.titleSort ?? book.title,
                    author: Self.displayAuthor(for: book),
                    authorRatingKey: book.authorRatingKey,
                    narrator: existing?.narrator,
                    summary: book.summary ?? existing?.summary,
                    year: book.year,
                    thumb: book.thumb,
                    trackCount: existing?.trackCount ?? book.leafCount,
                    durationMs: existing?.durationMs,
                    addedAt: book.addedAt,
                    plexUpdatedAt: book.updatedAt,
                    cachedAt: now,
                    language: book.language,
                    edition: book.edition,
                    identityKey: Self.identityKey(for: book, sectionID: sectionID)
                )
                try record.save(db)

                // Genres from the list response, when it carries them.
                //
                // Whether it does depends on the server: the detail endpoint
                // certainly does, the list endpoint may. Written here as well as
                // in `cache` so a library that supplies them is browsable by
                // genre after one refresh, rather than becoming so book by book
                // as each is opened.
                //
                // Empty still means "not asked" rather than "none" — see the
                // note in `cache`.
                try Self.replaceTags(db, table: "book_genre",
                                     bookRatingKey: book.ratingKey, values: book.genres)
                try Self.replaceTags(db, table: "book_narrator",
                                     bookRatingKey: book.ratingKey, values: book.narrators)
                try Self.replaceTags(db, table: "book_author",
                                     bookRatingKey: book.ratingKey, values: book.authors)
                try Self.replaceTags(db, table: "book_series",
                                     bookRatingKey: book.ratingKey, values: book.series)
                try Self.replaceSequences(db, bookRatingKey: book.ratingKey, values: book.sequences)
                try Self.claimHeldProgress(
                    db,
                    bookRatingKey: book.ratingKey,
                    identityKey: Self.identityKey(for: book, sectionID: sectionID)
                )
            }
        }
    }

    // MARK: - Reading

    /// One cached book, or nil if it has not been fetched yet.
    ///
    /// Exists so callers never touch `AudiobookDatabase.writer` themselves.
    /// Besides the layering argument, GRDB's `read` has both a synchronous and
    /// an asynchronous overload, and inside an `async` function the async one
    /// wins — producing "expression is 'async' but is not marked with 'await'"
    /// at a call site that looks entirely ordinary. A synchronous method here
    /// has no such ambiguity.
    public func book(ratingKey: String) throws -> BookRecord? {
        try database.writer.read { db in
            try BookRecord.fetchOne(db, key: ratingKey)
        }
    }

    // MARK: - Offline

    /// Books with every part on disk.
    ///
    /// `HAVING SUM(...) = 0` rather than `state = 'complete'` in the WHERE: a
    /// book halfway through downloading has some complete parts, and matching on
    /// any of them would put it in an offline library where most of it is
    /// missing. Playing that is worse than not seeing it — it works until the
    /// chapter where it does not.
    ///
    /// Written as a subquery rather than a join so it can be dropped into both
    /// the query-interface calls and the raw SQL ones without either having to
    /// know about the other, and takes the column rather than the table so a
    /// caller matching on `book_rating_key` can use it as easily as one matching
    /// on `rating_key`.
    static func downloadedOnlyFilter(_ column: String) -> String {
        """
        \(column) IN (
            SELECT book_rating_key FROM download
            GROUP BY book_rating_key
            HAVING SUM(CASE WHEN state = 'complete' THEN 0 ELSE 1 END) = 0
        )
        """
    }

    /// Which books are fully downloaded, as a set to look up against.
    ///
    /// One query per reload rather than one per tile: a library screen draws
    /// hundreds of covers, and asking the database about each one would be
    /// hundreds of round trips to answer a question with a single answer.
    ///
    /// The same subquery the offline filter uses, so "downloaded" cannot come to
    /// mean two things — a book the grid badges but offline mode hides would be
    /// worse than no badge.
    public func downloadedBookKeys() throws -> Set<String> {
        try database.writer.read { db in
            let keys = try String.fetchAll(db, sql: """
                SELECT book_rating_key FROM download
                GROUP BY book_rating_key
                HAVING SUM(CASE WHEN state = 'complete' THEN 0 ELSE 1 END) = 0
                """)
            return Set(keys)
        }
    }


    public func books(
        sectionID: String,
        limit: Int = 500,
        offset: Int = 0,
        downloadedOnly: Bool = false
    ) throws -> [BookRecord] {
        try database.writer.read { db in
            try BookRecord
                .filter(Column("library_section_id") == sectionID)
                .filter(sql: downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                .order(Column("title_sort").asc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Newest in the library first.
    ///
    /// `added_at` is when Plex saw the file, which is what someone means by
    /// "recently added" — not when this client cached it.
    public func recentlyAdded(
        sectionID: String,
        limit: Int = 12,
        downloadedOnly: Bool = false
    ) throws -> [BookRecord] {
        try database.writer.read { db in
            try BookRecord
                .filter(Column("library_section_id") == sectionID)
                .filter(Column("added_at") != nil)
                .filter(sql: downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                .order(Column("added_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Books with a position but no completion, most recently touched first.
    public func continueListening(limit: Int = 12, downloadedOnly: Bool = false) throws -> [BookRecord] {
        try database.writer.read { db in
            try BookRecord.fetchAll(
                db,
                sql: Self.continueListeningSQL(downloadedOnly: downloadedOnly),
                arguments: [limit]
            )
        }
    }

    /// Books finished, most recently first.
    ///
    /// The counterpart to Continue listening: that list is what is in progress,
    /// and this is what is behind you. A library screen shows what somebody
    /// owns; neither of those says what they have actually listened to.
    ///
    /// Ordered by when the book was finished rather than by title, because the
    /// question is "what have I just finished", not "what have I ever finished".
    ///
    /// `finished_at` is set by `markFinished` and cleared by `resetProgress`, so
    /// pressing the tick twice takes a book out of here as well.
    public func recentlyFinished(
        limit: Int = 12,
        downloadedOnly: Bool = false
    ) throws -> [BookRecord] {
        try database.writer.read { db in
            try BookRecord.fetchAll(db, sql: """
                SELECT book.* FROM book
                JOIN progress ON progress.book_rating_key = book.rating_key
                WHERE progress.finished_at IS NOT NULL
                  AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                ORDER BY progress.finished_at DESC
                LIMIT ?
                """, arguments: [limit])
        }
    }

    /// The same list, delivered again whenever it changes.
    ///
    /// The query is identical to `continueListening` and shares the SQL, so the
    /// two cannot drift into disagreeing about what "in progress" means.
    ///
    /// This exists because the alternative was a rule nobody can keep: every
    /// write that affects the list had to remember to tell the screen, through a
    /// counter the screen had to remember to watch. Thirty-four writes,
    /// forty-five signals, forty-four observers — and every failure in this area
    /// has been one missing link in that chain, silent by construction.
    ///
    /// GRDB knows when the tables change. A local position, a record arriving
    /// from iCloud, a position adopted from Plex, a purge — all identical from
    /// here, because all of them are writes to `progress`. The screen stops being
    /// something that has to be told and becomes something that reflects.
    ///
    /// The playing book is *not* filtered out here. Whether the player holds a
    /// book is not in the database, and a query that depended on it would have to
    /// be rebuilt every time playback changed. Callers drop it at the point of
    /// display, which is where that decision belongs.
    public func continueListeningStream(
        limit: Int = 12,
        downloadedOnly: Bool = false
    ) -> AsyncValueObservation<[BookRecord]> {
        let sql = Self.continueListeningSQL(downloadedOnly: downloadedOnly)
        return ValueObservation
            .tracking { db in try BookRecord.fetchAll(db, sql: sql, arguments: [limit]) }
            .values(in: database.writer)
    }

    private static func continueListeningSQL(downloadedOnly: Bool) -> String {
        """
        SELECT book.* FROM book
        JOIN progress ON progress.book_rating_key = book.rating_key
        WHERE progress.finished_at IS NULL AND progress.absolute_ms > 0
          AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
        ORDER BY progress.changed_at DESC
        LIMIT ?
        """
    }

    /// Every series in the library, with a cover or two and a count.
    ///
    /// Shaped like `genres()`, and deliberately so: the same tile, the same
    /// list, the same query pattern. A series is another way of grouping the
    /// same books.
    ///
    /// From the agent's `Series:` Moods rather than from Plex collections. A
    /// collection is whatever somebody dragged into it; a series membership is
    /// something the metadata states.
    public func series(sectionID: String, downloadedOnly: Bool = false) throws -> [SeriesSummary] {
        try database.writer.read { db in
            let sql = """
                SELECT book_series.name AS name, book.thumb AS thumb
                FROM book_series
                JOIN book ON book.rating_key = book_series.book_rating_key
                WHERE book.library_section_id = ?
                  AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                ORDER BY book_series.name COLLATE NOCASE ASC,
                         book.title_sort COLLATE NOCASE ASC
                """

            var order: [String] = []
            var counts: [String: Int] = [:]
            var covers: [String: [String]] = [:]

            for row in try Row.fetchAll(db, sql: sql, arguments: [sectionID]) {
                let name: String = row["name"]
                if counts[name] == nil { order.append(name) }
                counts[name, default: 0] += 1
                if let thumb = row["thumb"] as String?, covers[name, default: []].count < 4 {
                    covers[name, default: []].append(thumb)
                }
            }

            return order.map {
                SeriesSummary(name: $0, bookCount: counts[$0] ?? 0, covers: covers[$0] ?? [])
            }
        }
    }

    /// One series, in the order the agent says the books go.
    ///
    /// Ordered in Swift for the same reason `nextInSeries` is: a position is a
    /// string, `10` sorts before `2` as text, and a `CAST` turns anything
    /// non-numeric into zero and puts it first. Books whose position will not
    /// parse go last, in title order, rather than pretending to be book zero.
    ///
    /// A book in the series with no `Sequence:` tag at all still appears — it is
    /// in the series, the agent just did not say where.
    public func books(inSeries series: String, downloadedOnly: Bool = false) throws -> [SeriesEntry] {
        try database.writer.read { db in
            let sql = """
                SELECT book.rating_key AS rating_key,
                       book_sequence.position AS position
                FROM book_series
                JOIN book ON book.rating_key = book_series.book_rating_key
                LEFT JOIN book_sequence
                  ON book_sequence.book_rating_key = book.rating_key
                 AND book_sequence.series = book_series.name
                WHERE book_series.name = ?
                  AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                ORDER BY book.title_sort COLLATE NOCASE ASC
                """

            var placed: [(entry: SeriesEntry, sort: Double)] = []
            var unplaced: [SeriesEntry] = []

            for row in try Row.fetchAll(db, sql: sql, arguments: [series]) {
                guard let book = try BookRecord.fetchOne(db, key: row["rating_key"] as String)
                else { continue }

                let position = row["position"] as String?
                let entry = SeriesEntry(book: book, position: position)

                if let position, let value = Double(position) {
                    placed.append((entry, value))
                } else {
                    unplaced.append(entry)
                }
            }

            return placed.sorted { $0.sort < $1.sort }.map(\.entry) + unplaced
        }
    }

    /// Where a book sits among the ones this library actually holds.
    ///
    /// "Book 5 of 9" — and the nine is how many of that series are indexed here,
    /// not how many the publisher printed. The agent's contract is explicit that
    /// it does not know a trustworthy total and that a client calculating one
    /// must label it as library coverage. The screens say "in your library" for
    /// that reason; it is the difference between a fact and a guess dressed as
    /// one.
    ///
    /// Only for a book with a stated position, and only when the series has more
    /// than one member here. "Book 1 of 1" is a series of one book, which is a
    /// gap in the library rather than a fact about the series.
    public func standing(ofBook ratingKey: String) throws -> SeriesStanding? {
        try database.writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT series, position FROM book_sequence
                    WHERE book_rating_key = ?
                    ORDER BY series COLLATE NOCASE ASC
                    LIMIT 1
                    """,
                arguments: [ratingKey]
            ),
            let series = row["series"] as String?,
            let position = row["position"] as String?
            else { return nil }

            let held = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book_series WHERE name = ?",
                arguments: [series]
            ) ?? 0

            guard held > 1 else { return nil }
            return SeriesStanding(series: series, position: position, heldInLibrary: held)
        }
    }

    /// Who to show as the author of a book.
    ///
    /// The agent's first `Mood` author when it named any, and Plex's album
    /// artist otherwise.
    ///
    /// The album artist is whatever the files were tagged with, and for
    /// audiobooks that is very often the narrator — a library will happily show
    /// a biography of Elon Musk credited to Jeremy Bobb, who read it. The agent's
    /// author list is a statement about the book rather than about a tag, so
    /// where it exists it is the better answer.
    ///
    /// Only where it exists. A library nothing has matched has no `Mood` authors
    /// and keeps the album artist, which is all there is.
    static func displayAuthor(for book: PlexBook) -> String? {
        book.authors.first ?? book.author
    }

    /// Who wrote and read a book, and what it belongs to.
    ///
    /// One query rather than three: a book screen wants all of it at once, and
    /// three round trips to answer one question is three chances for two of them
    /// to disagree about what is cached.
    public func credits(bookRatingKey: String) throws -> BookCredits {
        try database.writer.read { db in
            func names(_ table: String) throws -> [String] {
                try String.fetchAll(
                    db,
                    sql: "SELECT name FROM \(table) WHERE book_rating_key = ? ORDER BY name COLLATE NOCASE",
                    arguments: [bookRatingKey]
                )
            }

            let book = try Row.fetchOne(
                db,
                sql: "SELECT language, edition FROM book WHERE rating_key = ?",
                arguments: [bookRatingKey]
            )

            return BookCredits(
                authors: try names("book_author"),
                narrators: try names("book_narrator"),
                series: try names("book_series"),
                language: book?["language"],
                edition: book?["edition"]
            )
        }
    }

    /// Rebuilds a timeline from cache.
    ///
    /// Returns nil rather than an empty timeline when the book has no cached
    /// tracks, so callers cannot mistake "not fetched yet" for "zero length".
    public func timeline(bookRatingKey: String) throws -> CachedTimeline? {
        try database.writer.read { db in
            let tracks = try TrackRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .order(Column("idx").asc)
                .fetchAll(db)
            guard !tracks.isEmpty else { return nil }

            let chapters = try ChapterRecord
                .filter(Column("book_rating_key") == bookRatingKey)
                .order(Column("idx").asc)
                .fetchAll(db)

            return CachedTimeline(
                bookRatingKey: bookRatingKey,
                segments: tracks.map {
                    BookTimeline.Segment(
                        trackRatingKey: $0.ratingKey,
                        trackKey: $0.plexKey,
                        partID: $0.partID,
                        partKey: $0.partKey,
                        partCacheKey: $0.partCacheKey,
                        title: $0.title,
                        startMs: $0.startMs,
                        durationMs: $0.durationMs
                    )
                },
                chapters: chapters.compactMap { record in
                    Chapter.Source(rawValue: record.source).map {
                        Chapter(
                            index: record.idx,
                            title: record.title,
                            startMs: record.startMs,
                            endMs: record.endMs,
                            source: $0
                        )
                    }
                }
            )
        }
    }

    // MARK: - Collections

    /// Replaces the cached collections for a section.
    ///
    /// Whole-section replace rather than upsert: a collection deleted on the
    /// server should disappear here too, and there is no other signal that it
    /// has gone.
    public func cacheCollections(
        _ collections: [(collection: PlexCollection, bookRatingKeys: [String])],
        sectionID: String,
        now: Date = Date()
    ) throws {
        try database.writer.write { db in
            try PlexCollectionRecord
                .filter(Column("library_section_id") == sectionID)
                .deleteAll(db)

            for entry in collections {
                let record = PlexCollectionRecord(
                    ratingKey: entry.collection.ratingKey,
                    librarySectionID: sectionID,
                    title: entry.collection.title,
                    titleSort: entry.collection.titleSort ?? entry.collection.title,
                    childCount: entry.collection.childCount ?? entry.bookRatingKeys.count,
                    thumb: entry.collection.thumb,
                    summary: entry.collection.summary,
                    cachedAt: now
                )
                try record.insert(db)

                for (index, bookRatingKey) in entry.bookRatingKeys.enumerated() {
                    let item = PlexCollectionItemRecord(
                        collectionRatingKey: entry.collection.ratingKey,
                        bookRatingKey: bookRatingKey,
                        position: index
                    )
                    try item.insert(db)
                }
            }
        }
    }

    /// Collections holding at least one fully downloaded book.
    private static var collectionsWithDownloadsFilter: String {
        """
        plex_collection.rating_key IN (
            SELECT collection_rating_key FROM plex_collection_item
            WHERE \(downloadedOnlyFilter("plex_collection_item.book_rating_key"))
        )
        """
    }

    /// Collections, and offline only the ones with something in them.
    ///
    /// A collection whose books are all on the server is an empty shelf when the
    /// network is gone — worse than absent, because it looks like the download
    /// was lost rather than never made.
    public func collections(sectionID: String, downloadedOnly: Bool = false) throws -> [PlexCollectionRecord] {
        try database.writer.read { db in
            let sql = """
                SELECT plex_collection.* FROM plex_collection
                WHERE plex_collection.library_section_id = ?
                  AND \(downloadedOnly ? Self.collectionsWithDownloadsFilter : "1")
                ORDER BY plex_collection.title_sort COLLATE NOCASE ASC
                """
            return try PlexCollectionRecord.fetchAll(db, sql: sql, arguments: [sectionID])
        }
    }

    /// The books in a collection, in Plex's own order — for a series, reading
    /// order, which is the only order worth showing.
    public func books(inCollection ratingKey: String, downloadedOnly: Bool = false) throws -> [BookRecord] {
        try database.writer.read { db in
            let sql = """
                SELECT book.* FROM book
                JOIN plex_collection_item ON plex_collection_item.book_rating_key = book.rating_key
                WHERE plex_collection_item.collection_rating_key = ?
                  AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                ORDER BY plex_collection_item.position ASC
                """
            return try BookRecord.fetchAll(db, sql: sql, arguments: [ratingKey])
        }
    }

    /// Authors, with how many books each has.
    ///
    /// Straight from the cache: Plex models the author as the album artist, and
    /// it is already on every book row, so this needs no network at all.
    /// Authors, with a few covers each.
    ///
    /// The covers are for the television, which cannot show a list of names and
    /// a number and call it browsing — there is no pointer, the row heights are
    /// enormous, and a focus ring around a line of text reads as nothing at all.
    /// A grid of cards needs art, and the art is already cached on the books.
    ///
    /// One query rather than a `GROUP BY` for the counts and one more per author
    /// for the covers. Grouping happens in Swift because SQLite cannot easily
    /// take "the first four thumbs per author in title order" out of a
    /// `GROUP BY`, and the alternative — a query per author — is one round trip
    /// per row of the grid.
    ///
    /// The cost is reading a row per book rather than one per author. That is
    /// the `book` table, not `track`: a library with fifty thousand track rows
    /// has a few thousand books, and two short columns across a few thousand
    /// rows is not something to optimise ahead of measuring. Worth knowing
    /// because the authors screens re-run this on every `libraryRevision` bump,
    /// and a full library sync bumps it once per page — so if this ever does
    /// become slow, that is where it will show.
    /// Every genre in a section, with a count and a few covers.
    ///
    /// Shaped like `authors` deliberately — the screen that draws them is the
    /// same screen with a different noun, and two queries that answer the same
    /// question should not answer it differently.
    ///
    /// A book has several genres, so a book appears under each of them. That is
    /// the point of a genre and the reason it needs its own table.
    public func genres(
        sectionID: String,
        coversPerGenre: Int = 4,
        downloadedOnly: Bool = false
    ) throws -> [GenreSummary] {
        try database.writer.read { db in
            let sql = """
                SELECT book_genre.name AS name, book.thumb AS thumb
                FROM book_genre
                JOIN book ON book.rating_key = book_genre.book_rating_key
                WHERE book.library_section_id = ?
                  AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                ORDER BY book_genre.name COLLATE NOCASE ASC,
                         book.title_sort COLLATE NOCASE ASC
                """

            var order: [String] = []
            var counts: [String: Int] = [:]
            var covers: [String: [String]] = [:]

            for row in try Row.fetchAll(db, sql: sql, arguments: [sectionID]) {
                let name: String = row["name"]
                if counts[name] == nil { order.append(name) }
                counts[name, default: 0] += 1

                // A book with no artwork must not take a collage slot and leave
                // a hole in it.
                if let thumb: String = row["thumb"], !thumb.isEmpty,
                   covers[name, default: []].count < coversPerGenre {
                    covers[name, default: []].append(thumb)
                }
            }

            return order.map {
                GenreSummary(name: $0, bookCount: counts[$0] ?? 0, covers: covers[$0] ?? [])
            }
        }
    }

    /// The books in one genre, in title order.
    public func books(
        inGenre genre: String,
        sectionID: String,
        downloadedOnly: Bool = false
    ) throws -> [BookRecord] {
        try database.writer.read { db in
            try BookRecord.fetchAll(db, sql: """
                SELECT book.* FROM book
                JOIN book_genre ON book_genre.book_rating_key = book.rating_key
                WHERE book_genre.name = ? AND book.library_section_id = ?
                  AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                ORDER BY book.title_sort COLLATE NOCASE ASC
                """, arguments: [genre, sectionID])
        }
    }

    public func authors(
        sectionID: String,
        coversPerAuthor: Int = 4,
        downloadedOnly: Bool = false
    ) throws -> [AuthorSummary] {
        try database.writer.read { db in
            // Two ways a book belongs to an author, unioned.
            //
            // `book.author` is Plex's album artist — one name, whoever the
            // scanner picked. `book_author` is every author the metadata agent
            // credited, which is what a co-written book actually has.
            //
            // Reading only the first meant a book by two writers appeared under
            // one of them and was missing from the other's page entirely. The
            // contract spells out the fix: albums under the artist, together
            // with albums whose Mood equals the name.
            //
            // `UNION` rather than `UNION ALL`: a book normally satisfies both
            // sides — its primary author is also one of its Mood authors — and
            // counting it twice would say a writer has forty books when they
            // have twenty.
            let sql = """
                SELECT name AS author, thumb, title_sort FROM (
                    SELECT book.author AS name, book.thumb AS thumb,
                           book.title_sort AS title_sort, book.rating_key AS rating_key
                    FROM book
                    WHERE book.library_section_id = ?
                      AND book.author IS NOT NULL AND book.author <> ''
                      AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")

                    UNION

                    SELECT book_author.name AS name, book.thumb AS thumb,
                           book.title_sort AS title_sort, book.rating_key AS rating_key
                    FROM book_author
                    JOIN book ON book.rating_key = book_author.book_rating_key
                    WHERE book.library_section_id = ?
                      AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                )
                ORDER BY author COLLATE NOCASE ASC, title_sort COLLATE NOCASE ASC
                """

            var order: [String] = []
            var counts: [String: Int] = [:]
            var covers: [String: [String]] = [:]

            for row in try Row.fetchAll(db, sql: sql, arguments: [sectionID, sectionID]) {
                let author: String = row["author"]
                if counts[author] == nil { order.append(author) }
                counts[author, default: 0] += 1

                // A book with no artwork must not take one of the four slots and
                // leave a hole in the collage.
                if let thumb: String = row["thumb"], !thumb.isEmpty,
                   covers[author, default: []].count < coversPerAuthor {
                    covers[author, default: []].append(thumb)
                }
            }

            return order.map { author in
                AuthorSummary(
                    name: author,
                    bookCount: counts[author] ?? 0,
                    covers: covers[author] ?? []
                )
            }
        }
    }

    public func books(
        byAuthor author: String,
        sectionID: String,
        downloadedOnly: Bool = false
    ) throws -> [BookRecord] {
        try database.writer.read { db in
            // The same union as `authors`: Plex's album artist, or any author the
            // agent credited. A co-written book belongs on both writers' pages.
            try BookRecord.fetchAll(db, sql: """
                SELECT book.* FROM book
                WHERE book.library_section_id = ?
                  AND \(downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                  AND (
                    book.author = ?
                    OR EXISTS (
                        SELECT 1 FROM book_author
                        WHERE book_author.book_rating_key = book.rating_key
                          AND book_author.name = ?
                    )
                  )
                ORDER BY book.title_sort COLLATE NOCASE ASC
                """, arguments: [sectionID, author, author])
        }
    }

    public func books(ratingKeys: [String]) throws -> [BookRecord] {
        guard !ratingKeys.isEmpty else { return [] }
        return try database.writer.read { db in
            try BookRecord.filter(keys: ratingKeys).fetchAll(db)
        }
    }

    /// The next book by the agent's stated positions.
    ///
    /// Ordered in Swift rather than SQL. A position is a string — `3.5` is a real
    /// position in most long series, and the contract reserves non-numeric ones —
    /// so `ORDER BY position` would put `10` before `2`, and a `CAST` would turn
    /// anything non-numeric into zero and place it first. Here a position that
    /// does not parse simply cannot be "next", which is the honest answer.
    ///
    /// A book can be in several series. The first with a successor wins, ordered
    /// by series name so the answer does not change between runs — the same
    /// arbitrary-but-stable rule the collection path uses, for the same reason:
    /// nothing says which series is *the* series.
    private func nextFromSequenceTags(after ratingKey: String) throws -> NextInSeries? {
        try database.writer.read { db in
            let current = try Row.fetchAll(
                db,
                sql: """
                    SELECT series, position FROM book_sequence
                    WHERE book_rating_key = ?
                    ORDER BY series COLLATE NOCASE ASC
                    """,
                arguments: [ratingKey]
            )

            for row in current {
                guard let series = row["series"] as String?,
                      let position = row["position"] as String?,
                      let here = Double(position)
                else { continue }

                let members = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT book_rating_key, position FROM book_sequence
                        WHERE series = ? AND book_rating_key != ?
                        """,
                    arguments: [series, ratingKey]
                )

                let candidate = members
                    .compactMap { member -> (key: String, position: Double, raw: String)? in
                        guard let key = member["book_rating_key"] as String?,
                              let raw = member["position"] as String?,
                              let value = Double(raw), value > here
                        else { return nil }
                        return (key, value, raw)
                    }
                    .min { $0.position < $1.position }

                guard let candidate,
                      let book = try BookRecord.fetchOne(db, key: candidate.key)
                else { continue }

                return NextInSeries(
                    book: book,
                    seriesTitle: series,
                    source: .seriesTag(position: candidate.raw)
                )
            }

            return nil
        }
    }


    /// The next book in the series this one belongs to.
    ///
    /// Finishing a book did nothing at all: the position was marked, the session
    /// closed, and the app sat on a finished book with no suggestion that book
    /// thirty-three exists. The information was already there — Plex collections
    /// carry their own order, which for a series is reading order, and
    /// `plex_collection_item.position` stores it.
    ///
    /// A book can be in several collections. The first one that has a successor
    /// wins, ordered by collection title so the answer does not change between
    /// runs — an arbitrary-but-stable choice, since nothing in Plex says which
    /// collection is "the series".
    ///
    /// Returns the collection as well as the book, because "next" is meaningless
    /// without saying next in *what*.
    public func nextInSeries(after ratingKey: String) throws -> NextInSeries? {
        // The agent's own answer first.
        //
        // A `Sequence: Discworld #6` tag states a position; a Plex collection is
        // whatever somebody put in it, in whatever order they dragged it into.
        // The contract is explicit that collections are user data and a series
        // should not be derived from them alone — so they stay, as the fallback
        // for a library the agent has not matched.
        if let fromTags = try nextFromSequenceTags(after: ratingKey) {
            return fromTags
        }

        return try database.writer.read { db in
            // Two steps rather than one join that also decodes the book.
            //
            // Building a `BookRecord` out of a joined row means the row carries
            // the book's columns *and* the collection's, and the record decodes
            // by name from whatever is there — which works until two tables
            // share a column name. `title` is on both.
            let sql = """
                SELECT following.book_rating_key AS next_key,
                       plex_collection.rating_key AS collection_key,
                       plex_collection.title AS collection_title
                FROM plex_collection_item AS current
                JOIN plex_collection_item AS following
                  ON following.collection_rating_key = current.collection_rating_key
                 AND following.position > current.position
                JOIN plex_collection
                  ON plex_collection.rating_key = current.collection_rating_key
                WHERE current.book_rating_key = ?
                ORDER BY plex_collection.title COLLATE NOCASE ASC,
                         following.position ASC
                LIMIT 1
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [ratingKey]),
                  let book = try BookRecord.fetchOne(db, key: row["next_key"] as String)
            else { return nil }

            return NextInSeries(
                book: book,
                seriesTitle: row["collection_title"],
                source: .collection(ratingKey: row["collection_key"])
            )
        }
    }

    public func search(_ query: String, limit: Int = 50, downloadedOnly: Bool = false) throws -> [BookRecord] {
        let pattern = "%\(query)%"
        return try database.writer.read { db in
            try BookRecord
                .filter(sql: "title LIKE ? OR author LIKE ?", arguments: [pattern, pattern])
                .filter(sql: downloadedOnly ? Self.downloadedOnlyFilter("book.rating_key") : "1")
                .order(Column("title_sort").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Sections

    /// Records the section, without claiming it has been synced.
    ///
    /// This used to stamp `lastSyncedAt` with the current time — but it is called
    /// when a library is *picked*, not when one is fetched, so the column held
    /// "when did somebody choose this" under a name that says otherwise. Nothing
    /// read it, so the lie was harmless until an incremental sync wanted an
    /// answer from it; then it would have skipped the entire first fetch.
    ///
    /// `markSynced` is the only thing that writes it now, and any existing value
    /// survives being re-picked.
    public func upsert(section: PlexLibrarySection, serverID: String, now: Date = Date()) throws {
        try database.writer.write { db in
            let id = "\(serverID):\(section.key)"
            let existing = try LibrarySectionRecord.fetchOne(db, key: id)
            let record = LibrarySectionRecord(
                id: id,
                serverID: serverID,
                sectionKey: section.key,
                title: section.title,
                lastSyncedAt: existing?.lastSyncedAt
            )
            try record.save(db)
        }
    }

    /// When this section was last fetched in full or in part.
    public func lastSynced(sectionID: String) throws -> Date? {
        try database.writer.read { db in
            try LibrarySectionRecord.fetchOne(db, key: sectionID)?.lastSyncedAt
        }
    }

    /// Stamps a completed fetch.
    ///
    /// Written after the pages have landed, never before: a stamp taken at the
    /// start would mark everything that changed *during* the sync as already
    /// seen, and those books would then never be fetched again.
    public func markSynced(sectionID: String, at now: Date = Date()) throws {
        try database.writer.write { db in
            guard var record = try LibrarySectionRecord.fetchOne(db, key: sectionID) else { return }
            record.lastSyncedAt = now
            try record.save(db)
        }
    }

    public func upsert(server: ResolvedConnection, name: String) throws {
        try database.writer.write { db in
            let record = ServerRecord(
                machineIdentifier: server.serverIdentifier,
                name: name,
                lastConnectedURI: server.baseURL.absoluteString,
                lastConnectedAt: server.resolvedAt,
                lastConnectionWasRelay: server.isRelay
            )
            try record.save(db)
        }
    }
}

/// One author and how many books of theirs are in the library.
public struct AuthorSummary: Sendable, Hashable, Identifiable {
    public let name: String
    public let bookCount: Int

    /// Up to a handful of this author's cover thumbs, in title order.
    ///
    /// Defaulted so the phone and the Mac, which show a list of names, are
    /// unaffected by a field only the television reads.
    public let covers: [String]

    public var id: String { name }

    public init(name: String, bookCount: Int, covers: [String] = []) {
        self.name = name
        self.bookCount = bookCount
        self.covers = covers
    }
}

/// A timeline rebuilt from cache. Distinct from `BookTimeline` because the
/// offsets are read back rather than recomputed — if the two ever disagree,
/// that is a bug worth catching rather than papering over.
public struct CachedTimeline: Sendable, Hashable {
    public let bookRatingKey: String
    public let segments: [BookTimeline.Segment]
    public let chapters: [Chapter]

    public var totalDurationMs: Int { segments.last?.endMs ?? 0 }

    /// Verifies the denormalised offsets are still self-consistent. Cheap
    /// enough to assert on load in debug builds.
    public var isConsistent: Bool {
        var expected = 0
        for segment in segments {
            if segment.startMs != expected { return false }
            expected += segment.durationMs
        }
        return true
    }
}

/// What comes after a book, and which series says so.
public struct NextInSeries: Sendable, Hashable {
    public let book: BookRecord

    /// What it is next *in*, which is the only thing the screens showed.
    ///
    /// Named for the meaning rather than the source. It was `collectionTitle`
    /// when a Plex collection was the only thing that could answer; the agent's
    /// `Sequence:` tags answer it better and have no collection behind them.
    public let seriesTitle: String

    /// Where the answer came from.
    ///
    /// Kept because the two are not equally trustworthy: a series tag comes from
    /// the metadata agent and states a position, while a collection is whatever
    /// somebody put in it in whatever order. Anything deciding how firmly to
    /// phrase "next" should be able to tell.
    public let source: Source

    public enum Source: Sendable, Hashable {
        /// A `Sequence: Discworld #6` tag, with a stated position.
        case seriesTag(position: String)
        /// A Plex collection's own order.
        case collection(ratingKey: String)
    }

    public init(book: BookRecord, seriesTitle: String, source: Source) {
        self.book = book
        self.seriesTitle = seriesTitle
        self.source = source
    }
}

/// Where a book sits in its series, among the books this library holds.
///
/// `heldInLibrary` is a count of what is indexed here and nothing more. The
/// metadata agent does not know how many books a series contains, so neither
/// does this — and a number presented as a total when it is a local count is
/// the kind of small lie somebody notices when they buy the tenth book.
public struct SeriesStanding: Sendable, Hashable {
    public let series: String
    public let position: String
    public let heldInLibrary: Int

    public init(series: String, position: String, heldInLibrary: Int) {
        self.series = series
        self.position = position
        self.heldInLibrary = heldInLibrary
    }
}

/// A series, with enough to draw a tile.
public struct SeriesSummary: Sendable, Hashable, Identifiable {
    public let name: String
    public let bookCount: Int
    public let covers: [String]

    public var id: String { name }

    public init(name: String, bookCount: Int, covers: [String]) {
        self.name = name
        self.bookCount = bookCount
        self.covers = covers
    }
}

/// One book within a series, and where the agent says it sits.
///
/// The position is optional and stays a string: a book can be in a series
/// without a stated position, and a stated one can be `3.5`.
public struct SeriesEntry: Sendable, Hashable, Identifiable {
    public let book: BookRecord
    public let position: String?

    public var id: String { book.ratingKey }

    public init(book: BookRecord, position: String?) {
        self.book = book
        self.position = position
    }
}

/// A genre, with enough to draw a tile.
///
/// The same shape as `AuthorSummary`, because the screen is the same screen.
/// What a book screen shows beyond the title: who wrote it, who read it, and
/// what it is part of.
///
/// Empty lists on a library no agent has matched, which is a metadata problem
/// rather than something the app can fix — and the screens say nothing rather
/// than showing a heading with nothing under it.
public struct BookCredits: Sendable, Hashable {
    public var authors: [String]
    public var narrators: [String]
    public var series: [String]

    /// The recording language, when the agent had evidence for one.
    ///
    /// Nil means unknown rather than English — the contract is explicit that
    /// absence carries no meaning, and a library of Swedish audiobooks would be
    /// mislabelled by any other reading.
    public var language: String?

    /// `Abridged` or `Unabridged`, when known.
    ///
    /// Also nil for unknown. Most unabridged recordings never say so, which is
    /// why the contract forbids inferring one from a missing tag.
    public var edition: String?

    public var isEmpty: Bool {
        authors.isEmpty && narrators.isEmpty && series.isEmpty
            && language == nil && edition == nil
    }

    /// The two joined for display, or nil when neither is known.
    ///
    /// One place decides how they read together, rather than three screens each
    /// choosing a separator and each having to remember that either half may be
    /// missing.
    public var editionLine: String? {
        let parts = [edition, language].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public init(
        authors: [String] = [],
        narrators: [String] = [],
        series: [String] = [],
        language: String? = nil,
        edition: String? = nil
    ) {
        self.authors = authors
        self.narrators = narrators
        self.series = series
        self.language = language
        self.edition = edition
    }
}

public struct GenreSummary: Sendable, Hashable, Identifiable {
    public let name: String
    public let bookCount: Int
    public let covers: [String]

    public var id: String { name }

    public init(name: String, bookCount: Int, covers: [String] = []) {
        self.name = name
        self.bookCount = bookCount
        self.covers = covers
    }
}
