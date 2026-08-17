import Foundation
import Testing
@testable import PlatformShared
@Suite("Chapter standing")
struct ChapterStandingTests {

    private func standing(position: Int, finished: Bool = false) -> ChapterStanding {
        ChapterStanding.of(
            chapterStartMs: 60_000,
            chapterEndMs: 120_000,
            positionMs: position,
            isFinished: finished
        )
    }

    @Test("Before it starts, ahead")
    func beforeStart() {
        #expect(standing(position: 30_000) == .ahead)
    }

    @Test("Inside it, playing — including the first millisecond")
    func insideChapter() {
        #expect(standing(position: 90_000) == .playing)
        #expect(standing(position: 60_000) == .playing)
    }

    /// The boundary belongs to the next chapter, not this one — the position at
    /// a chapter's end is the start of the one after it, and marking both as
    /// playing would light two rows at once.
    @Test("At its end, done")
    func atEnd() {
        #expect(standing(position: 120_000) == .done)
    }

    /// `markFinished` leaves the position where it was, so a book finished from
    /// the tick has a position that says nothing about how much was heard.
    /// Deriving from the position alone would tick chapters up to wherever
    /// somebody stopped and leave the rest unmarked on a book the app calls
    /// finished.
    @Test("A finished book has every chapter done, wherever the position sits")
    func finishedWins() {
        #expect(standing(position: 0, finished: true) == .done)
        #expect(standing(position: 90_000, finished: true) == .done)
    }

    /// A zero-length chapter is not a thing a timeline should contain, and is
    /// exactly what a malformed file produces. It reads as done rather than
    /// trapping or claiming to be playing forever.
    @Test("A chapter with no length is behind you, not around you")
    func zeroLength() {
        let result = ChapterStanding.of(
            chapterStartMs: 60_000, chapterEndMs: 60_000,
            positionMs: 60_000, isFinished: false
        )
        #expect(result == .done)
    }
}
