import Foundation
import Testing
@testable import PlatformShared

@Suite("Smart rewind")
struct SmartRewindTests {

    @Test("A brief pause does not rewind at all")
    func briefPauseDoesNothing() {
        #expect(SmartRewind.seconds(forGapSeconds: 0) == 0)
        #expect(SmartRewind.seconds(forGapSeconds: 14.9) == 0)
    }

    @Test("The tiers step up at the documented boundaries")
    func tierBoundaries() {
        #expect(SmartRewind.seconds(forGapSeconds: 15) == 3)
        #expect(SmartRewind.seconds(forGapSeconds: 599) == 3)
        #expect(SmartRewind.seconds(forGapSeconds: 600) == 10)
        #expect(SmartRewind.seconds(forGapSeconds: 3599) == 10)
        #expect(SmartRewind.seconds(forGapSeconds: 3600) == 30)
    }

    @Test("Overnight caps rather than growing without limit")
    func longGapIsCapped() {
        // Proportional rewind would send someone back an hour after sleeping,
        // which is worse than dropping them exactly where they left off.
        #expect(SmartRewind.seconds(forGapSeconds: 8 * 3600) == 30)
        #expect(SmartRewind.seconds(forGapSeconds: 90 * 86400) == 30)
    }

    @Test("Never rewinds forward")
    func neverNegative() {
        for gap in stride(from: 0.0, through: 7200, by: 37) {
            #expect(SmartRewind.seconds(forGapSeconds: gap) >= 0)
        }
    }
}
