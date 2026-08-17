import Testing
import Platform

// No `@testable import VocalisBook`.
//
// `PlaybackAction` moved into `Platform`, which is where it always belonged —
// and importing the app meant the test *launched* the app: under ad-hoc test
// signing, without entitlements, where CloudKit takes the process down before
// a single assertion runs. Three lines of string logic needed a running
// application to check.

@Suite("Playback action")
struct PlaybackActionTests {

    @Test("A book that is not playing offers to start or resume it")
    func notCurrent() {
        #expect(PlaybackAction.label(isCurrent: false, state: .idle, hasProgress: false) == "Play")
        #expect(PlaybackAction.label(isCurrent: false, state: .idle, hasProgress: true) == "Resume")
        // Another book playing does not change what this one offers.
        #expect(PlaybackAction.label(isCurrent: false, state: .playing, hasProgress: true) == "Resume")
    }

    @Test("The book on the player offers a transport control, not a restart")
    func current() {
        // The bug: this used to read "Play" while playing, and pressing it
        // reloaded the stream from the stored position.
        #expect(PlaybackAction.label(isCurrent: true, state: .playing, hasProgress: true) == "Pause")
        #expect(PlaybackAction.label(isCurrent: true, state: .paused, hasProgress: true) == "Resume")
        #expect(PlaybackAction.label(isCurrent: true, state: .buffering, hasProgress: true) == "Loading…")
    }

    @Test("Only actual playback shows the pause symbol")
    func symbols() {
        #expect(PlaybackAction.symbol(isCurrent: true, state: .playing) == "pause.fill")
        #expect(PlaybackAction.symbol(isCurrent: true, state: .buffering) == "play.fill")
        #expect(PlaybackAction.symbol(isCurrent: false, state: .playing) == "play.fill")
    }
}
