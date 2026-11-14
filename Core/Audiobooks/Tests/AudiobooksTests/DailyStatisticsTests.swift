import Foundation
import GRDB
import Testing
@testable import Audiobooks

@Suite("Accurate daily listening statistics")
struct DailyStatisticsTests {
    private func calendar(_ zone: String = "UTC", firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                      year: Int = 2026, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar()).date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @discardableResult
    private func record(_ store: SessionStore, from start: Date, to end: Date, section: String = "A:2") throws -> String {
        let id = try store.begin(bookRatingKey: "900", atMs: 1000, rate: 1.5, sectionID: section, now: start)
        try store.end(atMs: 2_701_000, now: end)
        return id
    }

    @Test("A midnight session contributes to both days and their history details")
    func crossingMidnight() throws {
        let db = try AudiobookDatabase.inMemory(), calendar = calendar()
        let store = SessionStore(database: db)
        let start = date(11, 12, 23, 50), end = date(11, 13, 0, 20)
        let id = try record(store, from: start, to: end)
        let before = try db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM listening_session") }
        let stats = try store.stats(sectionID: "A:2", now: end, calendar: calendar)
        #expect(stats.secondsPerDay == [date(11, 12): 600, date(11, 13): 1200])
        #expect(stats.allTimeSeconds == 1800 && stats.thisWeekSeconds == 1800)
        #expect(stats.currentStreak == 2 && stats.longestStreak == 2 && stats.daysListened == 2)
        #expect(stats.bestDay?.day == date(11, 13) && stats.bestDay?.seconds == 1200)
        let first = try #require(try store.sessions(on: start, sectionID: "A:2", now: end, calendar: calendar).first)
        let second = try #require(try store.sessions(on: end, sectionID: "A:2", now: end, calendar: calendar).first)
        #expect(first.id == id && second.id == id)
        #expect(first.startedAt == start && first.endedAt == date(11, 13) && first.seconds == 600)
        #expect(second.startedAt == date(11, 13) && second.endedAt == end && second.seconds == 1200)
        #expect(first.seconds + second.seconds == stats.allTimeSeconds)
        // Seeking/speed changes prevent inferring book offsets at midnight.
        #expect(first.startMs == 1000 && first.endMs == 2_701_000)
        #expect(second.startMs == first.startMs && second.endMs == first.endMs)
        let after = try db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM listening_session") }
        #expect(before == after, "daily statistics must never rewrite listening history")
    }

    @Test("A multi-day session credits every intervening calendar day")
    func multipleDays() throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar()
        let start = date(11, 9, 22), end = date(11, 11, 1)
        try record(store, from: start, to: end)
        let stats = try store.stats(sectionID: "A:2", now: end, calendar: calendar)
        #expect(stats.secondsPerDay == [date(11, 9): 7200, date(11, 10): 86400, date(11, 11): 3600])
        #expect(stats.allTimeSeconds == 97200 && stats.currentStreak == 3 && stats.longestStreak == 3)
        let middle = try #require(try store.sessions(on: date(11, 10), sectionID: "A:2", now: end, calendar: calendar).first)
        #expect(middle.seconds == 86400 && middle.startedAt == date(11, 10) && middle.endedAt == date(11, 11))
    }

    @Test("Midnight ends belong only to the preceding day")
    func exclusiveMidnightBoundary() throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar()
        let start = date(11, 12, 23), end = date(11, 13)
        try record(store, from: start, to: end)
        let now = date(11, 14)
        let stats = try store.stats(sectionID: "A:2", now: now, calendar: calendar)
        #expect(stats.secondsPerDay == [date(11, 12): 3600])
        #expect(try store.sessions(on: end, sectionID: "A:2", now: now, calendar: calendar).isEmpty)
        #expect(try store.sessions(on: date(11, 11), sectionID: "A:2", now: now, calendar: calendar).isEmpty)
    }

    @Test("Stockholm clock changes use real 23-hour and 25-hour days",
          arguments: [(month: 3, day: 29, hours: 23), (month: 10, day: 25, hours: 25)])
    func daylightSaving(change: (month: Int, day: Int, hours: Int)) throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar("Europe/Stockholm")
        let middle = date(change.month, change.day, calendar: calendar)
        let previous = calendar.date(byAdding: .day, value: -1, to: middle)!
        let next = calendar.date(byAdding: .day, value: 1, to: middle)!
        let start = middle.addingTimeInterval(-1800), end = next.addingTimeInterval(1800)
        try record(store, from: start, to: end)
        let stats = try store.stats(sectionID: "A:2", now: end, calendar: calendar)
        #expect(stats.secondsPerDay == [previous: 1800, middle: change.hours * 3600, next: 1800])
        #expect(stats.allTimeSeconds == (change.hours + 1) * 3600)
        #expect(stats.currentStreak == 3 && stats.longestStreak == 3)
        let sessions = try store.sessions(on: middle, sectionID: "A:2", now: end, calendar: calendar)
        #expect(sessions.count == 1 && sessions.first?.seconds == change.hours * 3600)
        #expect(sessions.first?.startedAt == middle && sessions.first?.endedAt == next)
    }

    @Test("A clock change at midnight keeps streaks and chart keys on day boundaries")
    func midnightClockChange() throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar("America/Sao_Paulo", firstWeekday: 1)
        // Brazil's 2018 spring transition skipped 00:00 through 00:59.
        let start = date(11, 3, 23, 30, year: 2018, calendar: calendar)
        let end = date(11, 5, 0, 30, year: 2018, calendar: calendar)
        try record(store, from: start, to: end)
        let stats = try store.stats(sectionID: "A:2", now: end, calendar: calendar)
        #expect(stats.currentStreak == 3 && stats.longestStreak == 3)
        let recent = stats.recentDays(3, now: end, calendar: calendar)
        #expect(recent.map(\.seconds) == [1800, 23 * 3600, 1800])
        #expect(recent.allSatisfy { $0.day == calendar.startOfDay(for: $0.day) })
        let week = stats.weekDays(now: end, calendar: calendar)
        #expect(week.count == 7 && week.allSatisfy { $0.day == calendar.startOfDay(for: $0.day) })
        #expect(week.reduce(0) { $0 + $1.seconds } == stats.thisWeekSeconds)
        let during = date(11, 4, 12, year: 2018, calendar: calendar)
        let snapshot = try store.stats(sectionID: "A:2", now: during, calendar: calendar)
        #expect(snapshot.recentDays(3, now: during, calendar: calendar)
            .allSatisfy { $0.day == calendar.startOfDay(for: $0.day) })
    }

    @Test("Changing the display timezone recalculates day boundaries from original dates")
    func changingTimeZone() throws {
        let store = SessionStore(database: try .inMemory())
        let start = date(6, 1, 23, 30), end = date(6, 2, 0, 30)
        try record(store, from: start, to: end)
        let utc = try store.stats(sectionID: "A:2", now: end, calendar: calendar())
        let swedishCalendar = calendar("Europe/Stockholm")
        let swedish = try store.stats(sectionID: "A:2", now: end, calendar: swedishCalendar)
        #expect(utc.secondsPerDay == [date(6, 1): 1800, date(6, 2): 1800])
        let localDay = swedishCalendar.startOfDay(for: start)
        #expect(swedish.secondsPerDay == [localDay: 3600])
        #expect(utc.allTimeSeconds == swedish.allTimeSeconds)
        #expect(utc.daysListened == 2 && swedish.daysListened == 1)
        #expect(try store.sessions(on: localDay, sectionID: "A:2", now: end, calendar: swedishCalendar).first?.seconds == 3600)
    }

    @Test("A Sunday-to-Monday session divides the calendar-week total and chart consistently")
    func weekBoundary() throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar()
        let start = date(11, 8, 23, 50), end = date(11, 9, 0, 10)
        try record(store, from: start, to: end)
        let stats = try store.stats(sectionID: "A:2", now: end, calendar: calendar)
        let days = stats.weekDays(now: end, calendar: calendar)
        #expect(stats.allTimeSeconds == 1200 && stats.thisWeekSeconds == 600)
        #expect(days.count == 7 && days.first?.day == date(11, 9) && days.last?.day == date(11, 15))
        #expect(days.map(\.seconds) == [600, 0, 0, 0, 0, 0, 0])
        #expect(days.reduce(0) { $0 + $1.seconds } == stats.thisWeekSeconds)
        #expect(days.filter { $0.seconds > 0 }.count == 1, "the average must not include last week's Sunday")
    }

    @Test("Weeks follow the user's first weekday", arguments: [1, 2, 7])
    func firstWeekday(firstWeekday: Int) throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar(firstWeekday: firstWeekday)
        let now = date(11, 11, 12)
        let week = try #require(calendar.dateInterval(of: .weekOfYear, for: now))
        try record(store, from: week.start.addingTimeInterval(-600), to: week.start.addingTimeInterval(600))
        let stats = try store.stats(sectionID: "A:2", now: now, calendar: calendar)
        let days = stats.weekDays(now: now, calendar: calendar)
        #expect(days.count == 7 && days.first?.day == week.start)
        #expect(calendar.component(.weekday, from: days[0].day) == firstWeekday)
        #expect(stats.thisWeekSeconds == 600 && days.reduce(0) { $0 + $1.seconds } == 600)
    }

    @Test("A week spanning New Year includes December's days")
    func yearBoundary() throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar()
        for start in [date(12, 28, 12, year: 2025), date(12, 29, 12, year: 2025), date(1, 1, 10)] {
            try record(store, from: start, to: start.addingTimeInterval(600))
        }
        let now = date(1, 1, 12)
        let stats = try store.stats(sectionID: "A:2", now: now, calendar: calendar)
        let days = stats.weekDays(now: now, calendar: calendar)
        #expect(days.count == 7 && days.first?.day == date(12, 29, year: 2025))
        #expect(stats.allTimeSeconds == 1800 && stats.thisWeekSeconds == 1200)
        #expect(days.reduce(0) { $0 + $1.seconds } == stats.thisWeekSeconds)
    }

    @Test("Future, open and nonpositive sessions do not invent listening time")
    func invalidAndFutureSessions() throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar()
        let now = date(11, 13, 12)
        try record(store, from: date(11, 13, 10), to: date(11, 13, 14))
        try record(store, from: date(11, 14, 10), to: date(11, 14, 11))
        try record(store, from: date(11, 13, 8), to: date(11, 13, 7))
        try record(store, from: date(11, 13, 9), to: date(11, 13, 9))
        try store.begin(bookRatingKey: "900", atMs: 0, rate: 1, sectionID: "A:2", now: date(11, 13, 11))
        let stats = try store.stats(sectionID: "A:2", now: now, calendar: calendar)
        #expect(stats.secondsPerDay == [date(11, 13): 7200])
        #expect(stats.allTimeSeconds == 7200 && stats.daysListened == 1 && stats.currentStreak == 1)
        let sessions = try store.sessions(on: now, sectionID: "A:2", now: now, calendar: calendar)
        #expect(sessions.count == 1 && sessions.first?.endedAt == now && sessions.first?.seconds == 7200)
        #expect(try store.sessions(on: date(11, 14), sectionID: "A:2", now: now, calendar: calendar).isEmpty)
    }

    @Test("Subsecond pause/resume sessions accumulate before daily rounding")
    func shortSessions() throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar()
        let start = date(11, 13, 10)
        for offset in 0..<10 {
            let sessionStart = start.addingTimeInterval(Double(offset))
            try record(store, from: sessionStart, to: sessionStart.addingTimeInterval(0.1))
        }
        let stats = try store.stats(sectionID: "A:2", now: start.addingTimeInterval(60), calendar: calendar)
        #expect(stats.secondsPerDay == [date(11, 13): 1])
        #expect(stats.allTimeSeconds == 1 && stats.daysListened == 1)
    }

    @Test("Library filtering and missing selections apply to every day slice")
    func libraryScope() throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar()
        let start = date(11, 12, 23, 50), end = date(11, 13, 0, 10)
        let a = try record(store, from: start, to: end)
        try record(store, from: start, to: end, section: "B:2")
        let stats = try store.stats(sectionID: "A:2", now: end, calendar: calendar)
        #expect(stats.allTimeSeconds == 1200)
        #expect(try store.sessions(on: end, sectionID: "A:2", now: end, calendar: calendar).map(\.id) == [a])
        #expect(try store.sessions(on: end, sectionID: nil, now: end, calendar: calendar).isEmpty)
        #expect(try store.stats(sectionID: nil, now: end, calendar: calendar).allTimeSeconds == 0)
    }

    @Test("Equal best-day totals select the earliest day consistently")
    func bestDayTies() throws {
        let store = SessionStore(database: try .inMemory()), calendar = calendar()
        for start in [date(11, 12, 10), date(11, 13, 10)] {
            try record(store, from: start, to: start.addingTimeInterval(600))
        }
        let stats = try store.stats(sectionID: "A:2", now: date(11, 13, 12), calendar: calendar)
        #expect(stats.bestDay?.day == date(11, 12) && stats.bestDay?.seconds == 600)
    }
}
