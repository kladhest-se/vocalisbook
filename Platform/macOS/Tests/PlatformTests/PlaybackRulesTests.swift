import Foundation
import Testing
@testable import Platform

/// The player's two arithmetic rules, which had no tests because they were
/// written inside closures nothing could reach.
///
/// `tests/README.md` has said for a long time that the player is the most
/// intricate thing in the project and the least covered, and named queue
/// rebuilding on a backwards seek and the sleep-timer fade specifically. Neither
/// needs a device. They needed extracting.
@Suite("Playback rules")
struct PlaybackRulesTests {

    // MARK: - Seeking

    @Test("A seek inside the current track stays in the current item")
    func seekWithinTrack() {
        #expect(
            PlaybackRules.seekPlan(toSegment: 3, currentSegment: 3, hasCurrentItem: true)
                == .seekInPlace
        )
    }

    /// The rule the whole design turns on: `AVQueuePlayer` only ever advances,
    /// so reaching an earlier track is not a seek but a replacement.
    @Test("A seek backwards rebuilds the queue")
    func seekBackwards() {
        #expect(
            PlaybackRules.seekPlan(toSegment: 1, currentSegment: 3, hasCurrentItem: true)
                == .rebuild(from: 1)
        )
    }

    @Test("A seek forwards rebuilds too, rather than advancing")
    func seekForwards() {
        // It could be done by advancing. One code path is easier to be right
        // about than two, and this one is already exercised on every backwards
        // seek.
        #expect(
            PlaybackRules.seekPlan(toSegment: 5, currentSegment: 3, hasCurrentItem: true)
                == .rebuild(from: 5)
        )
    }

    /// After a load that has not started playing there is no current item, and
    /// the indices agreeing means nothing.
    @Test("No current item rebuilds even when the indices agree")
    func noCurrentItem() {
        #expect(
            PlaybackRules.seekPlan(toSegment: 3, currentSegment: 3, hasCurrentItem: false)
                == .rebuild(from: 3)
        )
    }

    /// The queue holds every segment from the rebuild point onward, so an offset
    /// within it is an offset from *that point*. Forgetting the base is how a
    /// book that has been seeked once reports the wrong chapter for ever after.
    @Test("The playing segment is the queue's base plus the offset within it")
    func segmentIndexIncludesTheBase() {
        #expect(PlaybackRules.segmentIndex(queueBase: 0, offsetInQueue: 0) == 0)
        #expect(PlaybackRules.segmentIndex(queueBase: 0, offsetInQueue: 4) == 4)
        #expect(PlaybackRules.segmentIndex(queueBase: 7, offsetInQueue: 0) == 7)
        #expect(PlaybackRules.segmentIndex(queueBase: 7, offsetInQueue: 2) == 9)
    }

    // MARK: - Sleep timer

    @Test("A long timer plays, then fades for the last twenty seconds")
    func longTimerFadesAtTheEnd() {
        let plan = PlaybackRules.sleepFade(deadline: 30 * 60)
        #expect(plan.quiet == 30 * 60 - 20)
        #expect(plan.fade == 20)
    }

    /// The case that produces a negative wait if nobody thinks about it: a timer
    /// shorter than the fade must fade for the whole of it and start now.
    @Test("A timer shorter than the fade fades for its whole length")
    func shortTimerFadesThroughout() {
        let plan = PlaybackRules.sleepFade(deadline: 10)
        #expect(plan.quiet == 0)
        #expect(plan.fade == 10)
    }

    @Test("A timer of exactly the fade length starts fading immediately")
    func exactlyTheFadeLength() {
        let plan = PlaybackRules.sleepFade(deadline: 20)
        #expect(plan.quiet == 0)
        #expect(plan.fade == 20)
    }

    /// End-of-chapter on a chapter that has already ended, or a clock that has
    /// drifted, must not schedule a wait in the past.
    @Test("A deadline in the past is zero, not negative")
    func negativeDeadline() {
        let plan = PlaybackRules.sleepFade(deadline: -5)
        #expect(plan.quiet == 0)
        #expect(plan.fade == 0)
    }

    // MARK: - End of chapter

    /// Wall clock, not book time. At 2× a chapter with ten minutes left ends in
    /// five, and a timer that ignored the rate would leave the listener awake
    /// for the second half of it.
    @Test("End of chapter accounts for the playback rate")
    func endOfChapterUsesRate() {
        let atNormal = PlaybackRules.secondsToEndOfChapter(
            chapterEndMs: 600_000, positionMs: 0, rate: 1
        )
        let atDouble = PlaybackRules.secondsToEndOfChapter(
            chapterEndMs: 600_000, positionMs: 0, rate: 2
        )

        #expect(atNormal == 600)
        #expect(atDouble == 300)
    }

    @Test("Past the end of the chapter is zero rather than a negative wait")
    func pastTheEndOfChapter() {
        #expect(
            PlaybackRules.secondsToEndOfChapter(
                chapterEndMs: 600_000, positionMs: 700_000, rate: 1
            ) == 0
        )
    }

    /// A rate of zero is a paused player, and dividing by it would give infinity
    /// — which `Task.sleep` turns into a trap rather than a long wait.
    @Test("A rate of zero does not divide")
    func zeroRate() {
        #expect(
            PlaybackRules.secondsToEndOfChapter(
                chapterEndMs: 600_000, positionMs: 0, rate: 0
            ) == 0
        )
    }
    // MARK: - Persisting

    /// The threshold is on distance, not on wall clock, and these three are why.

    @Test("A small movement does not write")
    func smallMovementDoesNotPersist() {
        let write = PlaybackRules.shouldPersist(
            positionMs: 5_000, lastPersistedMs: 0, force: false
        )
        #expect(!write)
    }

    @Test("Ten seconds of movement writes, and the boundary is inclusive")
    func thresholdIsInclusive() {
        let atBoundary = PlaybackRules.shouldPersist(
            positionMs: 10_000, lastPersistedMs: 0, force: false
        )
        #expect(atBoundary)
    }

    /// Seeking backwards moves as far as seeking forwards, and both are worth
    /// recording — `abs`, not a subtraction that only counts one direction.
    @Test("Moving backwards counts as movement")
    func backwardsCountsToo() {
        let write = PlaybackRules.shouldPersist(
            positionMs: 30_000, lastPersistedMs: 300_000, force: false
        )
        #expect(write)
    }

    /// A paused player writes nothing, because nothing moves. A wall-clock
    /// threshold would have kept rewriting the same value for as long as the app
    /// was open.
    @Test("Standing still writes nothing, however long it stands")
    func standingStillDoesNotPersist() {
        let write = PlaybackRules.shouldPersist(
            positionMs: 123_456, lastPersistedMs: 123_456, force: false
        )
        #expect(!write)
    }

    /// Pausing, stopping and finishing all force a write. Those are the moments
    /// that decide where somebody resumes, and a nine-second stretch is still a
    /// stretch they listened to.
    @Test("Forcing writes even with no movement at all")
    func forceAlwaysPersists() {
        let write = PlaybackRules.shouldPersist(
            positionMs: 1_000, lastPersistedMs: 1_000, force: true
        )
        #expect(write)
    }

}

