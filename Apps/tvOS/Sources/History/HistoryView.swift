import SwiftUI
import Audiobooks
import PlatformShared

/// Listening history.
///
/// The shape Saga uses: a streak line, this week as a bar chart, then the recent
/// days broken into the sessions that made them. Everything here comes from the
/// `listening_session` table, which nothing wrote to until now — the numbers are
/// real, not estimated from position.
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var stats: ListeningStats?
    @State private var expandedDay: Date?
    @State private var sessions: [SessionSummary] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("History").font(.system(size: 56, weight: .semibold))

                if let stats {
                    // The cards are focusable, and that is the fix.
                    //
                    // `focusSection` was the previous attempt and did not work:
                    // grouping views does not create somewhere for focus to go.
                    // The first focusable view on this screen was a day row well
                    // down the page, so pressing up from it found nothing above
                    // and focus stayed put — the tab bar never came back and the
                    // Back button was the only way out.
                    //
                    // A television is navigated by focus, so anything you should
                    // be able to move *through* has to be focusable, even when
                    // there is nothing to press. Focus now steps up through the
                    // three cards and out to the tab bar, which is how every
                    // other screen here behaves and why they never had this
                    // problem: their top row is a grid of buttons.
                    StreakCard(stats: stats)
                        .focusable()
                    WeekCard(stats: stats)
                        .focusable()
                    AllTimeCard(stats: stats)
                        .focusable()

                    recentDays(stats)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.vertical, 40)
        }
        .background(theme.background.ignoresSafeArea())

        .task { reload() }
        .onChange(of: app.historyRevision) { _, _ in reload() }
    }

    /// The last fortnight, as cards along a row.
    ///
    /// This was a stack of list rows: a 34-point column, `caption2` type, a
    /// chevron, and a `.plain` button whose focus state was hand-painted black
    /// on white because tvOS whitens a focused row and leaves the content alone.
    /// It was a phone screen rendered on a television — readable from a foot
    /// away, illegible from a sofa, and navigated by pushing a remote down a
    /// column of thin rows.
    ///
    /// Cards in a horizontal row instead. `.buttonStyle(.card)` is the system's
    /// own focus treatment, which lifts, shadows and handles contrast — the
    /// hand-painted inversion existed only because a plain button gets none of
    /// that. A bar gives each day a size that can be compared at a glance, which
    /// is what somebody scanning a fortnight actually wants.
    @ViewBuilder
    private func recentDays(_ stats: ListeningStats) -> some View {
        let days = stats.recentDays(14).reversed().filter { $0.seconds > 0 }

        if days.isEmpty {
            Text("Nothing listened to yet. Sessions appear here as you go.")
                .font(.title3)
                .foregroundStyle(theme.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text("RECENT DAYS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)

                ScrollView(.horizontal) {
                    HStack(spacing: 28) {
                        ForEach(days, id: \.day) { entry in
                            Button {
                                if expandedDay == entry.day {
                                    expandedDay = nil
                                    sessions = []
                                } else {
                                    expandedDay = entry.day
                                    sessions = (try? app.sessions.sessions(on: entry.day)) ?? []
                                }
                            } label: {
                                DayCard(
                                    day: entry.day,
                                    seconds: entry.seconds,
                                    peak: days.map(\.seconds).max() ?? 1,
                                    isSelected: expandedDay == entry.day
                                )
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 12)
                }

                // Beneath the row rather than inside it.
                //
                // Expanding a card in place would resize it under the focus and
                // push its neighbours sideways, which on a remote means the
                // thing somebody just selected moves out from under them.
                if expandedDay != nil {
                    DaySessions(sessions: sessions)
                }
            }
        }
    }

    private func reload() {
        stats = try? app.sessions.stats()
        if let expandedDay {
            sessions = (try? app.sessions.sessions(on: expandedDay)) ?? []
        }
    }
}

struct StreakCard: View {
    let stats: ListeningStats
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(stats.currentStreak == 1 ? "1-day streak" : "\(stats.currentStreak)-day streak")
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Text("Longest run · \(stats.longestStreak) day\(stats.longestStreak == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            // A week of dots, filled for the days listened. Small enough to read
            // at a glance without being a second chart.
            HStack(spacing: 5) {
                ForEach(stats.recentDays(7), id: \.day) { entry in
                    Circle()
                        .fill(entry.seconds > 0 ? theme.accent : theme.track)
                        .frame(width: 9, height: 9)
                }
            }
        }
        .padding(14)
        .background(theme.surface, in: .rect(cornerRadius: 12))
    }
}

struct WeekCard: View {
    let stats: ListeningStats
    @Environment(\.theme) private var theme

    private var days: [(day: Date, seconds: Int)] { stats.recentDays(7) }
    private var peak: Int { max(days.map(\.seconds).max() ?? 0, 1) }
    private var daysWithListening: Int { days.filter { $0.seconds > 0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("THIS WEEK")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.tertiaryText)

            Text(Format.approximateDuration(ms: stats.thisWeekSeconds * 1000))
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(theme.text)

            if daysWithListening > 0 {
                Text("\(daysWithListening) day\(daysWithListening == 1 ? "" : "s") · "
                     + Format.approximateDuration(ms: stats.thisWeekSeconds * 1000 / daysWithListening)
                     + " / day")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days, id: \.day) { entry in
                    VStack(spacing: 6) {
                        // A bar is drawn even for an empty day, as a hairline —
                        // seven bars always, so the week keeps its shape.
                        RoundedRectangle(cornerRadius: 4)
                            .fill(entry.seconds > 0 ? theme.accent : theme.track)
                            .frame(height: max(6, 140 * Double(entry.seconds) / Double(peak)))
                        Text(Self.initial(for: entry.day))
                            .font(.caption2)
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
            .frame(height: 170, alignment: .bottom)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: 12))
    }

    private static func initial(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: day)
    }
}

/// One day, as a card sized for a television.
struct DayCard: View {
    let day: Date
    let seconds: Int
    let peak: Int
    let isSelected: Bool

    @Environment(\.theme) private var theme

    /// How tall this day's bar is against the busiest day shown.
    ///
    /// Against the peak rather than a fixed scale, so a quiet fortnight still
    /// has shape. A bar that is one pixel on every card says nothing.
    private var fraction: Double {
        guard peak > 0 else { return 0 }
        return min(1, Double(seconds) / Double(peak))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.weekday(day))
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.tertiaryText)

            Text(Self.dayNumber(day))
                .font(.system(size: 44, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.text)

            // The bar sits at the bottom of a fixed height, so the cards line up
            // whatever each day holds.
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.track)
                    .frame(height: 60)
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? theme.accent : theme.accent.opacity(0.7))
                    .frame(height: max(6, 60 * fraction))
            }
            .frame(width: 28)

            Text(Format.approximateDuration(ms: seconds * 1000))
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .padding(20)
        .background(theme.surface, in: .rect(cornerRadius: 14))
        // One element on a remote: read separately it is a weekday, a number, a
        // rectangle and a duration, with the rectangle announced as an image.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spokenDate(day))
        .accessibilityValue(Format.approximateDuration(ms: seconds * 1000))
    }

    private static func dayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }

    private static func spokenDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// What was listened to on the selected day.
struct DaySessions: View {
    let sessions: [SessionSummary]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sessions.isEmpty {
                Text("Nothing recorded for that day.")
                    .font(.title3)
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(sessions) { session in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.bookTitle)
                                .font(.title3)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Text(Format.approximateDuration(ms: session.seconds * 1000)
                                 + " listened")
                                .font(.callout)
                                .foregroundStyle(theme.secondaryText)
                        }

                        Spacer(minLength: 0)

                        Text(Self.clock(session.startedAt))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(theme.surface.opacity(0.6), in: .rect(cornerRadius: 12))
                    // Focusable, which is what makes them reachable.
                    //
                    // A television scrolls to follow focus, and these rows had
                    // none to give: the day cards above were the last focusable
                    // things on the screen, so pressing down did nothing and the
                    // sessions stayed below the fold, visible and unreadable.
                    //
                    // The same rule the cards above this screen already carry —
                    // anything you should be able to move *through* has to be
                    // focusable, even when there is nothing to press.
                    .focusable()
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Everything, rather than only this week.
///
/// A history screen that shows seven days says nothing after a month of use, and
/// on a television it is the screen somebody looks at from across the room —
/// three large numbers read better there than a dense list.
struct AllTimeCard: View {
    let stats: ListeningStats
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ALL TIME")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.tertiaryText)

            HStack(alignment: .top, spacing: 60) {
                figure(
                    Format.approximateDuration(ms: stats.allTimeSeconds * 1000),
                    caption: "listened"
                )

                figure(
                    "\(stats.daysListened)",
                    caption: stats.daysListened == 1 ? "day" : "days"
                )

                // Nil until something has been listened to: a personal best of
                // nothing is worse than no line at all.
                if let best = stats.bestDay {
                    figure(
                        Format.approximateDuration(ms: best.seconds * 1000),
                        caption: "best day"
                    )
                }

                if stats.daysListened > 0 {
                    figure(
                        Format.approximateDuration(
                            ms: stats.allTimeSeconds * 1000 / stats.daysListened
                        ),
                        caption: "per day"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(theme.surface, in: .rect(cornerRadius: 16))
    }

    private func figure(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(caption)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
        }
    }
}
