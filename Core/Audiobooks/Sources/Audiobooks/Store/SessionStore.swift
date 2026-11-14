import Foundation
import GRDB

/// Records what was listened to, and when.
///
/// The `listening_session` table has existed since the first migration and
/// nothing ever wrote to it, which is why there was no history and no streak to
/// show. A session opens when playback starts and closes when it stops for any
/// reason — pause, finishing, or switching books.
///
/// Plex cannot hold any of this: it has no concept of a listening session, only
/// a position. So this is local, and syncs via CloudKit like bookmarks.
public struct SessionStore: Sendable {
    private let database: AudiobookDatabase
    // Process-local active ID: a store recreated after a crash must not credit
    // the downtime by ending yesterday's session at today's wall clock.
    private let activeSession = ActiveSession()

    public init(database: AudiobookDatabase) {
        self.database = database
    }

    /// Called once at process startup, before playback begins. Querying through
    /// a newly constructed SessionStore never implicitly ends an active session.
    public func recoverInterruptedSessions() throws {
        try database.writer.write { db in try Self.closeOpenSessions(db) }
    }

    /// Opens a session, closing any that was left open.
    ///
    /// One is left open whenever the app is killed mid-playback, which happens
    /// often enough to matter. Rather than discard it, it is closed at the
    /// position it had reached — the listening happened, even if the app never
    /// got to say so.
    ///
    /// `sectionID` is the currently-selected `library_section.id` — the same
    /// composite `server:section` string `LibraryModel` and everything else
    /// scoped to one library already reads from `AppModel.sectionID`. Stored
    /// so history can later be shown only for the library it was actually
    /// recorded under; see `Schema.registerV10` for why that was not already
    /// true. `nil` when nothing is selected yet, which the row then carries
    /// forward exactly like any other unscoped session — visible nowhere,
    /// rather than guessed at.
    @discardableResult
    public func begin(
        bookRatingKey: String, atMs: Int, rate: Float, sectionID: String?, now: Date = Date()
    ) throws -> String {
        let id = UUID().uuidString
        try database.writer.write { db in
            try Self.closeOpenSessions(db)
            try db.execute(
                sql: """
                    INSERT INTO listening_session
                        (id, book_rating_key, started_at, ended_at, start_ms, end_ms, rate,
                         revision, dirty, library_section_id, origin_device_id, last_listened_at, last_listened_ms)
                    VALUES (?, ?, ?, NULL, ?, NULL, ?, 1, 1, ?,
                            (SELECT identifier FROM local_device WHERE singleton = 1), ?, ?)
                    """,
                arguments: [id, bookRatingKey, now, atMs, Double(rate), sectionID, now, atMs]
            )

        }
        activeSession.set(id)
        return id
    }

    /// Save confirmed playback periodically; a future process recovers only up
    /// to this checkpoint, never through time spent outside the application.
    public func checkpoint(atMs: Int, now: Date = Date()) throws {
        guard let id = activeSession.value else { return }
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE listening_session
                SET last_listened_at = ?, last_listened_ms = ?, revision = revision + 1, dirty = 1
                WHERE id = ? AND ended_at IS NULL AND started_at <= ?
                  AND (last_listened_at IS NULL OR last_listened_at < ?)
                  AND origin_device_id = (SELECT identifier FROM local_device WHERE singleton = 1)
                """, arguments: [now, atMs, id, now, now])
        }
    }

    /// Closes the open session at a position.
    public func end(atMs: Int, now: Date = Date()) throws {
        guard let id = activeSession.value else { return }
        try database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE listening_session
                    SET ended_at = ?, end_ms = ?, revision = revision + 1, dirty = 1
                    WHERE ended_at IS NULL
                      AND id = ?
                      AND origin_device_id = (SELECT identifier FROM local_device WHERE singleton = 1)
                    """,
                arguments: [now, atMs, id]
            )

        }
        activeSession.set(nil)
    }

    /// A session with no end is one the app never got to close.
    ///
    /// Closed at its last confirmed checkpoint, or its start for older rows.
    /// Recovery never credits the time since the application disappeared.
    private static func closeOpenSessions(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE listening_session
            SET ended_at = MAX(started_at, COALESCE(last_listened_at, started_at)),
                end_ms = COALESCE(last_listened_ms, start_ms), revision = revision + 1, dirty = 1
            WHERE ended_at IS NULL
              AND origin_device_id = (SELECT identifier FROM local_device WHERE singleton = 1)
            """)
    }

    /// Closed rows only: an abandoned open row cannot prove how long playback
    /// lasted. Ignore invalid intervals and never credit future wall-clock time.
    private static func closedInterval(start: Date, end: Date, now: Date) -> DateInterval? {
        let end = min(end, now)
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite, start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }

    // MARK: - Statistics

    /// Everything the history screen needs, in one pass over closed sessions.
    /// Elapsed time is split by the display calendar's days and capped at `now`;
    /// speed and seeks do not change how much wall-clock time was listened.
    ///
    /// A personal library's worth of sessions is small enough to compute in
    /// Swift; doing the calendar arithmetic in SQL would mean trusting SQLite's
    /// timezone handling, which is not worth it for a streak.
    ///
    /// Scoped to `sectionID` — see `begin(bookRatingKey:atMs:rate:sectionID:)`
    /// for what that value is and why. `nil` returns empty stats rather than
    /// querying with no filter at all: no library selected is not the same
    /// question as "every session ever recorded regardless of library", and
    /// answering it that way would be exactly the unscoped behavior this
    /// exists to replace.
    public func stats(
        sectionID: String?, now: Date = Date(), calendar: Calendar = .current
    ) throws -> ListeningStats {
        guard let sectionID else {
            return ListeningStats(currentStreak: 0, longestStreak: 0, thisWeekSeconds: 0, secondsPerDay: [:])
        }

        let rows: [(start: Date, end: Date)] = try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT started_at, ended_at FROM listening_session
                WHERE ended_at IS NOT NULL AND library_section_id = ?
                ORDER BY started_at ASC
                """, arguments: [sectionID])
            .compactMap { row in
                guard let start: Date = row["started_at"], let end: Date = row["ended_at"] else {
                    return nil
                }
                return (start, end)
            }
        }

        // Split elapsed listening at local calendar boundaries. Adding 86,400
        // seconds is not a calendar day when daylight-saving time changes.
        // Sum SQLite's millisecond precision before converting a day's total
        // to whole seconds, so short pause/resume sessions are not all lost.
        var intervals: [DateInterval] = []
        for row in rows {
            guard let interval = Self.closedInterval(start: row.start, end: row.end, now: now) else { continue }
            if let last = intervals.last, interval.start <= last.end {
                intervals[intervals.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { intervals.append(interval) }
        }
        // Simultaneous recordings on multiple devices describe one elapsed
        // period. Union them before splitting into calendar-day contributions.
        var millisecondsPerDay: [Date: Int] = [:]
        for interval in intervals {
            var cursor = interval.start
            while cursor < interval.end,
                  let day = calendar.dateInterval(of: .day, for: cursor), day.end > cursor {
                let end = min(interval.end, day.end)
                millisecondsPerDay[day.start, default: 0] += Self.milliseconds(from: cursor, to: end)
                cursor = end
            }
        }
        let perDay = millisecondsPerDay.mapValues { $0 / 1000 }.filter { $0.value > 0 }

        let today = calendar.startOfDay(for: now)
        let listened = Set(perDay.keys)

        // The streak survives today being empty — it is only broken once a whole
        // day has passed with nothing in it. Otherwise every morning would show
        // a streak of zero until the first session.
        var current = 0
        var cursor = listened.contains(today)
            ? today
            : calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: today)!)
        while listened.contains(cursor) {
            current += 1
            cursor = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: cursor)!)
        }

        var longest = 0
        var run = 0
        var previous: Date?
        for day in listened.sorted() {
            if let previous,
               let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.startOfDay(for: next) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }

        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let weekStart = week?.start ?? today
        let weekEnd = week?.end ?? now
        let thisWeek = perDay
            .filter { $0.key >= weekStart && $0.key < weekEnd }
            .values
            .reduce(0, +)

        // The best day, and nil rather than zero when there is no best day: a
        // personal record of nothing is worse than no line at all.
        let best = perDay.max {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        }

        return ListeningStats(
            currentStreak: current,
            longestStreak: longest,
            thisWeekSeconds: thisWeek,
            allTimeSeconds: perDay.values.reduce(0, +),
            bestDay: best.map { (day: $0.key, seconds: $0.value) },
            daysListened: perDay.count,
            secondsPerDay: perDay
        )
    }

    /// Closed sessions overlapping a day, newest first. Dates and duration are
    /// clipped to that day and `now`; book offsets retain the original session's
    /// values because seeks and speed changes make interpolation unreliable.
    ///
    /// Scoped the same way `stats(sectionID:...)` is, and for the same reason
    /// — see its doc comment.
    public func sessions(
        on day: Date, sectionID: String?, now: Date = Date(), calendar: Calendar = .current
    ) throws -> [SessionSummary] {
        guard let sectionID else { return [] }

        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        let start = interval.start
        let end = min(interval.end, now)
        guard start < end else { return [] }

        return try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT listening_session.*, book.title AS book_title, book.thumb AS book_thumb
                FROM listening_session
                LEFT JOIN book ON book.rating_key = listening_session.book_rating_key
                WHERE started_at < ? AND ended_at > ?
                  AND ended_at > started_at AND listening_session.library_section_id = ?
                ORDER BY started_at DESC, listening_session.id ASC
                """, arguments: [end, start, sectionID])
            .compactMap { row in
                guard let started: Date = row["started_at"], let ended: Date = row["ended_at"] else {
                    return nil
                }
                return SessionSummary(
                    id: row["id"],
                    bookRatingKey: row["book_rating_key"],
                    bookTitle: row["book_title"] ?? "Unknown book",
                    bookThumb: row["book_thumb"],
                    startedAt: max(started, start),
                    endedAt: min(ended, end),
                    startMs: row["start_ms"] ?? 0,
                    endMs: row["end_ms"] ?? 0
                )
            }
        }
    }
}

public struct ListeningStats: Sendable, Equatable {
    public let currentStreak: Int
    public let longestStreak: Int
    public let thisWeekSeconds: Int

    /// Closed listening time in the selected library, including synced sessions.
    ///
    /// Worth stating plainly on a history screen, which otherwise only ever
    /// shows a week: after a few months the interesting number is not what
    /// happened since Sunday.
    public let allTimeSeconds: Int

    /// The most listened in a single day, and which day.
    ///
    /// Nil until something has been listened to. A personal best of zero on a
    /// fresh install is worse than no line at all.
    public let bestDay: (day: Date, seconds: Int)?

    /// Days with anything on them, which is what "2m / day" is averaged over.
    public let daysListened: Int
    /// Start of day to seconds listened.
    public let secondsPerDay: [Date: Int]

    /// Written out because a tuple member has no synthesised `==`.
    public static func == (lhs: ListeningStats, rhs: ListeningStats) -> Bool {
        lhs.currentStreak == rhs.currentStreak
            && lhs.longestStreak == rhs.longestStreak
            && lhs.thisWeekSeconds == rhs.thisWeekSeconds
            && lhs.allTimeSeconds == rhs.allTimeSeconds
            && lhs.daysListened == rhs.daysListened
            && lhs.bestDay?.day == rhs.bestDay?.day
            && lhs.bestDay?.seconds == rhs.bestDay?.seconds
            && lhs.secondsPerDay == rhs.secondsPerDay
    }

    /// Written out rather than synthesised, because this type is `public` and a
    /// memberwise initialiser would be `internal` — so it has to be kept in step
    /// by hand every time a figure is added. Adding three and forgetting this is
    /// what broke the build.
    ///
    /// The all-time figures default, so a caller that only has a week of
    /// numbers — a preview, a test — does not have to invent them.
    public init(
        currentStreak: Int,
        longestStreak: Int,
        thisWeekSeconds: Int,
        allTimeSeconds: Int = 0,
        bestDay: (day: Date, seconds: Int)? = nil,
        daysListened: Int = 0,
        secondsPerDay: [Date: Int]
    ) {
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.thisWeekSeconds = thisWeekSeconds
        self.allTimeSeconds = allTimeSeconds
        self.bestDay = bestDay
        self.daysListened = daysListened
        self.secondsPerDay = secondsPerDay
    }

    /// The current calendar week's days, including empty/future days. The
    /// history chart and its per-day average use the same week as the total.
    public func weekDays(now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, seconds: Int)] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        var days: [(day: Date, seconds: Int)] = []
        var day = week.start
        while day < week.end {
            days.append((day, day <= now ? secondsPerDay[day] ?? 0 : 0))
            guard let next = calendar.dateInterval(of: .day, for: day)?.end, next > day else { break }
            day = next
        }
        return days
    }

    /// Seconds listened on each of the last `count` days, oldest first.
    public func recentDays(_ count: Int, now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, seconds: Int)] {
        guard count > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: today)!)
            return (day, secondsPerDay[day] ?? 0)
        }
    }
}

/// A saved session's contribution to the requested day. Time bounds are clipped
/// for display; book offsets describe the original session and are not inferred.
public struct SessionSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let bookRatingKey: String
    public let bookTitle: String
    public let bookThumb: String?
    public let startedAt: Date
    public let endedAt: Date
    public let startMs: Int
    public let endMs: Int

    public var seconds: Int { max(0, Int((endedAt.timeIntervalSince(startedAt) * 1000).rounded()) / 1000) }
}

private final class ActiveSession: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return id }
    func set(_ value: String?) { lock.lock(); defer { lock.unlock() }; id = value }
}
