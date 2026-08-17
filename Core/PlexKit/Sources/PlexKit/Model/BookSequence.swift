import Foundation

/// Where a book sits in a series, from a `Sequence: Discworld #5` Mood.
///
/// Two Moods carry what one cannot. `Series: Discworld` stays exactly matchable
/// so grouping is a string comparison; the position varies per book and would
/// break that if folded in. This is the second half.
public struct BookSequence: Sendable, Hashable {

    /// The series this position is within, matching a `Series:` Mood exactly.
    public let series: String

    /// The position as the agent normalised it: `5`, `3.5`, `4` from `Book IV`.
    ///
    /// Kept as a string. It can be a decimal — a novella between two books is
    /// `3.5` and is a real thing in most long series — and the contract reserves
    /// non-numeric positions for later. Parsing it to an `Int` would silently
    /// drop every novella; parsing to a `Double` would still lose whatever comes
    /// next.
    public let position: String

    /// The position as a number, when it is one.
    ///
    /// For ordering. `nil` for anything that is not, which sorts last rather
    /// than being coerced to zero and sorting first.
    public var numericPosition: Double? { Double(position) }

    public init(series: String, position: String) {
        self.series = series
        self.position = position
    }

    /// Reads the part after `Sequence: `.
    ///
    /// Split at the **final** ` #`, as the contract requires: a series name may
    /// contain spaces, and it may contain a hash. Splitting at the first would
    /// turn "Hitchhiker's #1 Guide #2" into a series called "Hitchhiker's" at
    /// position "1 Guide #2".
    public init?(mood: String) {
        guard let separator = mood.range(of: " #", options: .backwards) else { return nil }

        let series = String(mood[mood.startIndex..<separator.lowerBound])
        let position = String(mood[separator.upperBound...])
        guard !series.isEmpty, !position.isEmpty else { return nil }

        self.series = series
        self.position = position
    }
}
