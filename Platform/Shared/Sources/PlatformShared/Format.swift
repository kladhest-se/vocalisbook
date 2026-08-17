import Foundation

/// Durations, formatted for reading.
///
/// One copy. This lived in all three app targets and had already drifted — a
/// function added to the iOS one and missing from the other two, which is
/// exactly the duplication the single repository was meant to end.
public enum Format {

    /// A clock: "1:04:12".
    ///
    /// Books run to dozens of hours, so the hours component is not optional
    /// padding — minutes running past 59 because the hours were never carried is
    /// the classic bug in this function.
    public static func duration(ms: Int) -> String {
        let total = max(0, ms) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// A phrase: "4h 8m".
    ///
    /// For figures nobody acts on to the second — time remaining, time listened
    /// this week. Never "0m": a book with forty seconds left says so in words.
    public static func approximateDuration(ms: Int) -> String {
        let minutes = max(0, ms) / 60_000
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Words: "4 hours 8 minutes".
    ///
    /// For VoiceOver, which reads "1:04:12" as "one oh four twelve" — a number,
    /// not a duration. `approximateDuration` is not a substitute: "4h 8m" is
    /// read letter by letter, and the abbreviations that make a label short read
    /// worst of all aloud.
    ///
    /// Seconds are included only under a minute, matching what a listener would
    /// say. Announcing the seconds of a thirty-hour book on every scrub tick is
    /// noise nobody can act on.
    public static func spoken(ms: Int) -> String {
        let total = max(0, ms) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60

        if hours == 0 && minutes == 0 {
            let seconds = total % 60
            return seconds == 1 ? "1 second" : "\(seconds) seconds"
        }

        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        return parts.joined(separator: " ")
    }

    /// A playback speed: "1×", "1.5×", "0.75×".
    ///
    /// Written out rather than interpolated with `specifier:`. That form is a
    /// `LocalizedStringKey` feature — it works inside `Text("...")` and `Button`
    /// titles and nowhere else, so the same string that compiles in a label
    /// fails as a `String` argument with "incorrect argument label in call".
    /// Eleven places were formatting speed, several of them by copying a line
    /// that only worked where it happened to sit.
    ///
    /// `%g` drops trailing zeros, which is the whole point: 1× rather than
    /// 1.0×, and 1.5× rather than 1.50×.
    /// Generic over the floating-point types actually in play.
    ///
    /// `player.rate` is a `Float` because `AVPlayer`'s is, and the speed menus
    /// are arrays of literals, which default to `Double`. A `Float`-only version
    /// compiles at half the call sites and fails at the rest — which is what
    /// happened, and is a duller version of the same lesson as `specifier:`: a
    /// helper that works in one context and not the neighbouring one is a
    /// helper that will be copied wrong.
    public static func speed(_ rate: some BinaryFloatingPoint) -> String {
        String(format: "%g×", Double(rate))
    }

    /// The same number without the multiplication sign, for spoken output —
    /// VoiceOver reads "×" as "times" only sometimes, and "1.5 times" said
    /// plainly is never wrong.
    public static func spokenSpeed(_ rate: some BinaryFloatingPoint) -> String {
        String(format: "%g times", Double(rate))
    }
}

