
/// What the book screen's main button offers next.
///
/// Pure, and separate from the view model, because this is the thing that was
/// wrong: the button read "Play" while the book was already playing, and pressing
/// it reloaded the stream and discarded the position. Logic that subtle should be
/// testable without a player.
///
/// In this module rather than in each app, which is what made testing it
/// expensive: the test had to `@testable import VocalisBook`, so running it
/// launched the whole application — under ad-hoc test signing, without
/// entitlements, where creating a `CKContainer` for a container the process is
/// not entitled to use takes the process down. Three lines of string logic
/// needed a running app, an iCloud account and a Plex server to check.
///
/// It belongs here anyway: it is about `AudiobookPlayer.State`, which is here.
public enum PlaybackAction {

    public static func label(isCurrent: Bool, state: AudiobookPlayer.State, hasProgress: Bool) -> String {
        guard isCurrent else {
            return hasProgress ? "Resume" : "Play"
        }
        switch state {
        case .playing: return "Pause"
        case .buffering: return "Loading…"
        case .paused, .idle: return "Resume"
        }
    }

    public static func symbol(isCurrent: Bool, state: AudiobookPlayer.State) -> String {
        isCurrent && state == .playing ? "pause.fill" : "play.fill"
    }
}
