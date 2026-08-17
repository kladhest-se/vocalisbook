import Foundation
import Testing
@testable import PlatformShared

@Suite("Duration formatting")
struct FormatTests {

    @Test("Under an hour omits the hours component")
    func shortDurations() {
        #expect(Format.duration(ms: 0) == "0:00")
        #expect(Format.duration(ms: 9_000) == "0:09")
        #expect(Format.duration(ms: 65_000) == "1:05")
        #expect(Format.duration(ms: 3_599_000) == "59:59")
    }

    @Test("Books run to dozens of hours, and the hours carry properly")
    func longDurations() {
        // The classic bug is minutes running past 59 because the hours are never
        // carried, producing "1439:59" for a day-long book.
        #expect(Format.duration(ms: 3_600_000) == "1:00:00")
        #expect(Format.duration(ms: 3_661_000) == "1:01:01")
        #expect(Format.duration(ms: 86_399_000) == "23:59:59")
        #expect(Format.duration(ms: 90_000_000) == "25:00:00")
    }

    @Test("A negative position renders as zero rather than a negative clock")
    func negativeClamps() {
        // Reachable: the remaining-time label is total minus position, and a
        // stale position from another device can exceed the current duration.
        #expect(Format.duration(ms: -1) == "0:00")
        #expect(Format.approximateDuration(ms: -500_000) == "less than a minute")
    }

    @Test("Approximate durations read as phrases, never as 0m")
    func approximate() {
        #expect(Format.approximateDuration(ms: 40_000) == "less than a minute")
        #expect(Format.approximateDuration(ms: 60_000) == "1m")
        #expect(Format.approximateDuration(ms: 59 * 60_000) == "59m")
        #expect(Format.approximateDuration(ms: 3_600_000) == "1h")
        #expect(Format.approximateDuration(ms: 3_600_000 + 8 * 60_000) == "1h 8m")
        #expect(Format.approximateDuration(ms: 14_880_000) == "4h 8m")
    }

    /// VoiceOver reads "1:04:12" as a number, not a duration, and reads "4h 8m"
    /// letter by letter. The scrubber's value has to be words.
    @Test("Spoken durations are words")
    func spokenDurations() {
        #expect(Format.spoken(ms: 3_600_000) == "1 hour")
        #expect(Format.spoken(ms: 7_200_000) == "2 hours")
        #expect(Format.spoken(ms: 3_660_000) == "1 hour 1 minute")
        #expect(Format.spoken(ms: 33 * 3_600_000 + 51 * 60_000) == "33 hours 51 minutes")
    }

    /// Seconds appear only when there is nothing larger to say. Announcing the
    /// seconds of a thirty-hour book on every scrub tick is noise.
    @Test("Spoken durations fall back to seconds under a minute")
    func spokenSeconds() {
        #expect(Format.spoken(ms: 0) == "0 seconds")
        #expect(Format.spoken(ms: 1_000) == "1 second")
        #expect(Format.spoken(ms: 45_000) == "45 seconds")
        // Ninety seconds is a minute; the remaining thirty are not mentioned.
        #expect(Format.spoken(ms: 90_000) == "1 minute")
    }

    /// A negative position is a bug elsewhere, but it must not become
    /// "minus 1 hours" in someone's ear.
    @Test("Negative durations clamp")
    func spokenNegative() {
        #expect(Format.spoken(ms: -5) == "0 seconds")
    }

    /// `specifier:` is a `LocalizedStringKey` feature: it works inside
    /// `Text("...")` and a `Button` title and nowhere else. Eleven places were
    /// formatting speed by copying a line that only compiled where it happened
    /// to sit, and the twelfth — a plain `String` argument — did not.
    @Test("Speeds drop their trailing zeros")
    func speeds() {
        #expect(Format.speed(1) == "1×")
        #expect(Format.speed(2) == "2×")
        #expect(Format.speed(1.5) == "1.5×")
        #expect(Format.speed(0.75) == "0.75×")
        #expect(Format.speed(1.25) == "1.25×")
    }

    /// Both types reach this, and a `Float`-only version compiled at half the
    /// call sites: `player.rate` is a `Float` because `AVPlayer`'s is, and the
    /// speed menus are arrays of literals, which are `Double`.
    @Test("Float and Double give the same answer")
    func bothFloatingPointTypes() {
        let asFloat: Float = 1.5
        let asDouble: Double = 1.5

        #expect(Format.speed(asFloat) == "1.5×")
        #expect(Format.speed(asDouble) == "1.5×")
        #expect(Format.spokenSpeed(asFloat) == Format.spokenSpeed(asDouble))
    }

    /// VoiceOver reads "×" as "times" only sometimes. Said plainly it is never
    /// wrong.
    @Test("Spoken speeds say the word")
    func spokenSpeeds() {
        #expect(Format.spokenSpeed(1) == "1 times")
        #expect(Format.spokenSpeed(1.5) == "1.5 times")
    }
}

