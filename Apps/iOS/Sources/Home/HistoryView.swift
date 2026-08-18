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
                if let stats {
                    StreakCard(stats: stats)
                    WeekCard(stats: stats)
                    recentDays(stats)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(20)
            .padding(.bottom, 90)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onChange(of: app.historyRevision) { _, _ in reload() }
    }

    @ViewBuilder
    private func recentDays(_ stats: ListeningStats) -> some View {
        let days = stats.recentDays(14).reversed().filter { $0.seconds > 0 }

        if days.isEmpty {
            Text("Nothing listened to yet. Sessions appear here as you go.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        } else {
            Text("RECENT DAYS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.tertiaryText)
                .padding(.top, 4)

            ForEach(days, id: \.day) { entry in
                DayRow(
                    day: entry.day,
                    seconds: entry.seconds,
                    isExpanded: expandedDay == entry.day,
                    sessions: expandedDay == entry.day ? sessions : []
                ) {
                    if expandedDay == entry.day {
                        expandedDay = nil
                        sessions = []
                    } else {
                        expandedDay = entry.day
                        sessions = (try? app.sessions.sessions(on: entry.day, sectionID: app.sectionID)) ?? []
                    }
                }
            }
        }
    }

    private func reload() {
        stats = try? app.sessions.stats(sectionID: app.sectionID)
        if let expandedDay {
            sessions = (try? app.sessions.sessions(on: expandedDay, sectionID: app.sectionID)) ?? []
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
                .font(.system(size: 34, weight: .semibold))
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
                            .frame(height: max(4, 90 * Double(entry.seconds) / Double(peak)))
                        Text(Self.initial(for: entry.day))
                            .font(.caption2)
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
            .frame(height: 110, alignment: .bottom)
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

struct DayRow: View {
    let day: Date
    let seconds: Int
    let isExpanded: Bool
    let sessions: [SessionSummary]
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.dayNumber(day))
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(theme.accent)
                        Text(Self.weekday(day))
                            .font(.caption2)
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .frame(width: 34, alignment: .leading)

                    Text(Format.approximateDuration(ms: seconds * 1000))
                        .font(.subheadline)
                        .foregroundStyle(theme.text)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryText)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(sessions) { session in
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.bookTitle)
                                .font(.footnote)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Text(Format.approximateDuration(ms: session.seconds * 1000) + " listened")
                                .font(.caption2)
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        Text(Self.clock(session.startedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .padding(.leading, 46)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(theme.surface.opacity(isExpanded ? 1 : 0.5), in: .rect(cornerRadius: 10))
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

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
