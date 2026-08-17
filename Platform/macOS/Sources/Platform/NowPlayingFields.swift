import Foundation
import MediaPlayer

/// What the system's Now Playing card is told, as a value rather than a side
/// effect.
///
/// `NowPlayingController` builds this dictionary from a live `AudiobookPlayer`
/// and writes it straight to `MPNowPlayingInfoCenter`, so none of the decisions
/// in it could be examined without a player and a running system. They are
/// decisions worth examining: every one of them was learned from a card that
/// showed the wrong thing, or no card at all.
enum NowPlayingFields {

    /// - Parameters:
    ///   - rate: the *chosen* speed, whether or not playback is running. It is
    ///     reported separately from the effective rate below.
    static func fields(
        title: String,
        author: String?,
        chapterTitle: String?,
        durationMs: Int,
        positionMs: Int,
        rate: Float,
        isPlaying: Bool
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000,
            // Zero while paused, because this is the rate playback is *moving*
            // at and the system interpolates the scrubber from it. Left at the
            // chosen speed, a paused book's scrubber would keep sliding.
            //
            // `0.0`, never `0`. In a `[String: Any]` literal there is no
            // contextual type to unify the two branches of the ternary, so the
            // integer literal stays an `Int` and the dictionary holds an `Int`
            // for a field documented as a number of type double. It bridges to
            // `NSNumber` either way, which is why this went unnoticed in the
            // controller for as long as it did — a test asking for a `Double`
            // back is what found it.
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            // And the chosen speed, separately, so the system still knows a book
            // plays at 1.5× when it resumes.
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            // A book is not a live stream, and saying so is what gets a scrubber
            // rather than a spinner.
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]

        // Omitted rather than blank: an empty artist line is a line the card
        // still reserves room for.
        if let author, !author.isEmpty {
            info[MPMediaItemPropertyArtist] = author
        }

        // The chapter becomes the title and the book becomes the album.
        //
        // A single-file m4b otherwise reads as one endless item with the same
        // name in both lines, which is the least useful thing the Lock Screen
        // could be showing during a thirty-hour book.
        if let chapterTitle, !chapterTitle.isEmpty {
            info[MPMediaItemPropertyTitle] = chapterTitle
            info[MPMediaItemPropertyAlbumTitle] = title
        }

        return info
    }

    /// What the system is told about playback, which on macOS and tvOS it will
    /// not infer.
    ///
    /// Without `playbackState` those platforms have the metadata and no session,
    /// and show nothing at all — which is why the tvOS app never appeared in
    /// Control Centre. On iOS the audio session implies it, so the omission was
    /// invisible on the one platform being looked at.
    static func playbackState(isPlaying: Bool, isBuffering: Bool, isIdle: Bool) -> MPNowPlayingPlaybackState {
        if isIdle { return .stopped }
        // Buffering reports as playing on purpose. A stall is not a pause, and a
        // card that flips to paused every time a chunk is slow reads as the app
        // stopping by itself.
        if isBuffering { return .playing }
        return isPlaying ? .playing : .paused
    }
}
