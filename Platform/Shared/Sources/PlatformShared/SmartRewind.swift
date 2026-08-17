import Foundation

/// How far to seek back when resuming after a pause.
///
/// Picking up mid-sentence after a long gap is disorienting. Tiered rather than
/// proportional so the behaviour is learnable: a listener should be able to
/// predict what the app will do, and "eight percent of the gap" is not
/// predictable by anybody.
///
/// Pulled out of `AudiobookPlayer` because it is the one piece of that class
/// with no AVFoundation in it, and therefore the one piece that can be tested
/// without a device and an ear.
public enum SmartRewind {
    /// Seconds to rewind after a pause of `gapSeconds`.
    public static func seconds(forGapSeconds gap: TimeInterval) -> Int {
        switch gap {
        // A brief pause is deliberate — answering a question, crossing a road.
        // Rewinding there is not helpful, it is repetitive.
        case ..<15:   0
        case ..<600:  3
        case ..<3600: 10
        default:      30
        }
    }
}

/// Where a chapter stands relative to where somebody is in a book.
///
/// A chapter list with nothing marked is a list of times: it says what the book
/// contains and nothing about what has been listened to, which is the question
/// somebody opening it is usually asking.
///
/// Here rather than in each screen. The rule was written four times — three book
/// screens and the television's player list — and four copies of one comparison
/// is how the phone comes to disagree with the television about which chapter is
/// playing.
public enum ChapterStanding: Sendable, Hashable {
    /// The position has passed the end of this chapter.
    case done
    /// The position is inside this chapter.
    case playing
    /// The position has not reached it.
    case ahead

    /// Which of the three a chapter is.
    ///
    /// `isFinished` is checked first and separately, because `markFinished`
    /// leaves the position where it was: a book finished from the tick has every
    /// chapter behind it while the position may sit anywhere. Deriving that from
    /// the position alone would tick chapters up to wherever somebody stopped
    /// and leave the rest unmarked on a book the app calls finished.
    public static func of(
        chapterStartMs: Int,
        chapterEndMs: Int,
        positionMs: Int,
        isFinished: Bool
    ) -> ChapterStanding {
        if isFinished { return .done }
        if positionMs >= chapterEndMs { return .done }
        if positionMs >= chapterStartMs { return .playing }
        return .ahead
    }
}
