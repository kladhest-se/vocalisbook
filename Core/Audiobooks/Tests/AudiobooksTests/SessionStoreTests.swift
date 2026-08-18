import Foundation
import Testing
@testable import Audiobooks

@Suite("Listening sessions")
struct SessionStoreTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2   // Monday, so "this week" is not a US week.
        return calendar
    }

    private func day(_ offset: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: now)!
    }

    private func makeStore() throws -> (SessionStore, AudiobookDatabase) {
        let db = try AudiobookDatabase.inMemory()
        return (SessionStore(database: db), db)
    }

    @Test("A session records the wall clock, not the distance moved")
    func recordsWallClock() throws {
        let (store, _) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        try store.begin(bookRatingKey: "900", atMs: 0, rate: 1.5, sectionID: "test-section", now: start)
        // Ninety minutes of book in one hour, at 1.5x.
        try store.end(atMs: 5_400_000, now: start.addingTimeInterval(3600))

        let stats = try store.stats(sectionID: "test-section", now: start.addingTimeInterval(3600), calendar: calendar)
        let today = calendar.startOfDay(for: start)
        #expect(stats.secondsPerDay[today] == 3600, "the hour, not the ninety minutes")
    }

    @Test("Consecutive days build a streak")
    func streakCounts() throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        for offset in [-2, -1, 0] {
            let start = day(offset, from: now)
            try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "test-section", now: start)
            try store.end(atMs: 600_000, now: start.addingTimeInterval(600))
        }

        let stats = try store.stats(sectionID: "test-section", now: now, calendar: calendar)
        #expect(stats.currentStreak == 3)
        #expect(stats.longestStreak == 3)
    }

    @Test("A missed day breaks the streak but not the record")
    func gapBreaksStreak() throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Four days, then nothing, then today.
        for offset in [-6, -5, -4, -3, 0] {
            let start = day(offset, from: now)
            try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "test-section", now: start)
            try store.end(atMs: 600_000, now: start.addingTimeInterval(600))
        }

        let stats = try store.stats(sectionID: "test-section", now: now, calendar: calendar)
        #expect(stats.currentStreak == 1)
        #expect(stats.longestStreak == 4)
    }

    @Test("Nothing today does not break a streak that ran until yesterday")
    func todayNotYetListened() throws {
        // Otherwise every morning would show zero until the first session, which
        // is both wrong and discouraging.
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        for offset in [-2, -1] {
            let start = day(offset, from: now)
            try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "test-section", now: start)
            try store.end(atMs: 600_000, now: start.addingTimeInterval(600))
        }

        let stats = try store.stats(sectionID: "test-section", now: now, calendar: calendar)
        #expect(stats.currentStreak == 2)
    }

    @Test("A session the app never closed is credited nothing, not everything")
    func abandonedSessionIsZeroLength() throws {
        // Happens whenever the app is killed mid-playback. Crediting the gap
        // until the next launch would invent days of listening.
        let (store, _) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "test-section", now: start)
        // No end. Three days later, another session opens.
        let later = start.addingTimeInterval(3 * 86_400)
        try store.begin(bookRatingKey: "901", atMs: 0, rate: 1, sectionID: "test-section", now: later)
        try store.end(atMs: 600_000, now: later.addingTimeInterval(600))

        let stats = try store.stats(sectionID: "test-section", now: later, calendar: calendar)
        #expect(stats.secondsPerDay[calendar.startOfDay(for: start)] == nil)
        #expect(stats.currentStreak == 1)
    }

    @Test("Sessions for a day come back newest first, with their book")
    func sessionsForADay() throws {
        let (store, _) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "test-section", now: start)
        try store.end(atMs: 600_000, now: start.addingTimeInterval(600))
        try store.begin(bookRatingKey: "900", atMs: 600_000, rate: 1, sectionID: "test-section", now: start.addingTimeInterval(1800))
        try store.end(atMs: 1_200_000, now: start.addingTimeInterval(2400))

        let sessions = try store.sessions(on: start, sectionID: "test-section", calendar: calendar)
        #expect(sessions.count == 2)
        #expect(sessions.first?.startedAt ?? .distantPast > sessions.last?.startedAt ?? .distantFuture)
        #expect(sessions.allSatisfy { $0.seconds == 600 })
    }

    @Test("Recent days include the empty ones")
    func recentDaysPadsGaps() throws {
        // A bar chart with missing days silently compressed is a chart that
        // lies about the shape of a week.
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let start = day(-2, from: now)
        try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "test-section", now: start)
        try store.end(atMs: 600_000, now: start.addingTimeInterval(600))

        let stats = try store.stats(sectionID: "test-section", now: now, calendar: calendar)
        let week = stats.recentDays(7, now: now, calendar: calendar)
        #expect(week.count == 7)
        #expect(week.filter { $0.seconds > 0 }.count == 1)
        #expect(week.last?.day == calendar.startOfDay(for: now))
    }

    /// A history screen that only ever shows seven days says nothing after a
    /// month of use. These three are what it says instead.
    @Test("All-time totals count every day, not just this week")
    func allTimeTotals() throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Three days spread wider than a week: 10 minutes, 30, then 5.
        for (offset, minutes) in [(-20, 10), (-9, 30), (-1, 5)] {
            let start = day(offset, from: now)
            try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "test-section", now: start)
            try store.end(atMs: 0, now: start.addingTimeInterval(Double(minutes) * 60))
        }

        let stats = try store.stats(sectionID: "test-section", now: now, calendar: calendar)

        #expect(stats.allTimeSeconds == 45 * 60)
        #expect(stats.daysListened == 3)
        // The week's total is a subset, which is the entire reason to show both.
        #expect(stats.thisWeekSeconds < stats.allTimeSeconds)
    }

    @Test("The best day is the longest one, with its date")
    func bestDay() throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = day(-9, from: now)

        for (offset, minutes) in [(-20, 10), (-9, 30), (-1, 5)] {
            let start = day(offset, from: now)
            try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "test-section", now: start)
            try store.end(atMs: 0, now: start.addingTimeInterval(Double(minutes) * 60))
        }

        let stats = try store.stats(sectionID: "test-section", now: now, calendar: calendar)
        let best = try #require(stats.bestDay)

        #expect(best.seconds == 30 * 60)
        #expect(calendar.isDate(best.day, inSameDayAs: expected))
    }

    /// A personal best of nothing is worse than no line at all, so the screen
    /// needs to be able to tell the difference.
    @Test("A fresh install has no best day rather than a best day of zero")
    func noBestDayYet() throws {
        let (store, _) = try makeStore()
        let stats = try store.stats(
            sectionID: "test-section",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            calendar: calendar
        )

        #expect(stats.bestDay == nil)
        #expect(stats.allTimeSeconds == 0)
        #expect(stats.daysListened == 0)
    }

    /// Two sessions on one day are one day, which is what the "per day" average
    /// divides by.
    @Test("Days listened counts days, not sessions")
    func daysNotSessions() throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = day(-2, from: now)

        try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "test-section", now: start)
        try store.end(atMs: 0, now: start.addingTimeInterval(600))
        try store.begin(bookRatingKey: "901", atMs: 0, rate: 1, sectionID: "test-section", now: start.addingTimeInterval(3_600))
        try store.end(atMs: 0, now: start.addingTimeInterval(4_200))

        let stats = try store.stats(sectionID: "test-section", now: now, calendar: calendar)

        #expect(stats.daysListened == 1)
        #expect(stats.allTimeSeconds == 1_200)
    }
}

