import Foundation

/// The decisions inside the player that are arithmetic rather than AVFoundation.
///
/// `AudiobookPlayer` is 550 lines, is the most intricate thing in the project by
/// its own README's account, and had no tests at all — because everything in it
/// is tangled with `AVQueuePlayer`, which needs real assets and a real clock.
/// These two rules are not tangled with anything. They were simply written
/// inside closures where nothing could reach them.
///
/// Same move as `DownloadFileNaming`: the extraction is the work, the tests are
/// the easy part, and the fact that the extraction is easy is the evidence it
/// was worth doing.
enum PlaybackRules {

    // MARK: - Seeking

    /// What a seek needs, given where the queue currently is.
    enum SeekPlan: Equatable {
        /// The target is inside the item already playing.
        case seekInPlace
        /// The queue has to be rebuilt from this segment.
        ///
        /// `AVQueuePlayer` only ever advances, so reaching an earlier track is
        /// not a seek at all — the queue is replaced from that point. Reaching a
        /// *later* one could be done by advancing, but rebuilding is the same
        /// operation and one code path is easier to be right about than two.
        case rebuild(from: Int)
    }

    static func seekPlan(
        toSegment target: Int,
        currentSegment: Int,
        hasCurrentItem: Bool
    ) -> SeekPlan {
        // Without an item there is nothing to seek within, whatever the indices
        // say — which happens after a load that has not started playing.
        guard target == currentSegment, hasCurrentItem else {
            return .rebuild(from: target)
        }
        return .seekInPlace
    }

    /// Which segment is playing, from the queue's base and the current item's
    /// position within what was enqueued.
    ///
    /// The queue holds every segment from the rebuild point onward, so the
    /// offset within it is an offset from that point and not from the start of
    /// the book. Forgetting the base is how a book that has been seeked once
    /// reports the wrong chapter for ever after.
    static func segmentIndex(queueBase: Int, offsetInQueue: Int) -> Int {
        queueBase + offsetInQueue
    }

    // MARK: - Sleep timer

    /// When to start fading, and for how long.
    struct SleepFade: Equatable {
        /// How long to play at full volume before the fade begins.
        let quiet: TimeInterval
        /// How long the fade itself runs.
        let fade: TimeInterval
    }

    /// Fading the last stretch rather than cutting: an abrupt stop wakes people
    /// up, which defeats the entire point of the feature.
    ///
    /// The case worth having a name for is a timer shorter than the fade. Five
    /// minutes gives 4:40 of playback and a 20-second fade; *ten seconds* must
    /// give a ten-second fade and no wait, not a negative wait and a fade
    /// running past the deadline.
    static func sleepFade(deadline: TimeInterval, fade: TimeInterval = 20) -> SleepFade {
        let deadline = max(0, deadline)
        return SleepFade(
            quiet: max(0, deadline - fade),
            fade: min(fade, deadline)
        )
    }

    /// How long until the end of the current chapter, at the current speed.
    ///
    /// Wall clock, not book time: at 2× a chapter with ten minutes left ends in
    /// five, and a sleep timer that ignored the rate would leave the listener
    /// awake for the second half of it.
    static func secondsToEndOfChapter(
        chapterEndMs: Int,
        positionMs: Int,
        rate: Float
    ) -> TimeInterval {
        guard rate > 0 else { return 0 }
        return max(0, Double(chapterEndMs - positionMs) / 1000 / Double(rate))
    }

    // MARK: - Persisting

    /// Whether a position is far enough from the last saved one to write again.
    ///
    /// Every ten seconds of *movement*, not of wall clock. A distance threshold
    /// means a seek always writes — jumping a chapter moves far more than ten
    /// seconds — while a paused player writes nothing, because nothing moves.
    /// A time threshold would have got both of those backwards.
    ///
    /// `force` is for the moments that must be recorded whatever the distance:
    /// pausing, stopping, and finishing a book. Those are the writes that decide
    /// where somebody resumes, and a nine-second stretch is still a stretch
    /// somebody listened to.
    ///
    /// Extracted for the same reason as the rules above it: this decides where a
    /// listener resumes, is pure arithmetic, and was written inside a private
    /// method on a class that needs a real `AVQueuePlayer` to exist at all.
    static func shouldPersist(
        positionMs: Int,
        lastPersistedMs: Int,
        force: Bool,
        thresholdMs: Int = 10_000
    ) -> Bool {
        force || abs(positionMs - lastPersistedMs) >= thresholdMs
    }
}
