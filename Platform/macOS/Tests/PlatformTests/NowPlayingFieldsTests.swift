import Foundation
import MediaPlayer
import Testing
@testable import Platform

/// What the Lock Screen, Control Centre and the Apple TV's Now Playing panel are
/// told.
///
/// Every rule here came from a card that showed the wrong thing or no card at
/// all, and none of them could be examined before: the dictionary was built from
/// a live player and written straight to `MPNowPlayingInfoCenter`.
@Suite("Now Playing fields")
struct NowPlayingFieldsTests {

    private func fields(
        title: String = "A Hat Full of Sky",
        author: String? = "Terry Pratchett",
        chapterTitle: String? = nil,
        durationMs: Int = 30_000_000,
        positionMs: Int = 60_000,
        rate: Float = 1,
        isPlaying: Bool = true
    ) -> [String: Any] {
        NowPlayingFields.fields(
            title: title,
            author: author,
            chapterTitle: chapterTitle,
            durationMs: durationMs,
            positionMs: positionMs,
            rate: rate,
            isPlaying: isPlaying
        )
    }

    @Test("Times are seconds, because the system counts in seconds")
    func timesAreSeconds() {
        let info = fields(durationMs: 30_000_000, positionMs: 60_000)

        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 30_000)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 60)
    }

    /// The scrubber is interpolated from the rate. Left at the chosen speed
    /// while paused, a paused book's scrubber keeps sliding across the Lock
    /// Screen.
    @Test("A paused book reports a rate of zero")
    func pausedRateIsZero() {
        let info = fields(rate: 1.5, isPlaying: false)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }

    /// And the chosen speed goes separately, so the system still knows the book
    /// resumes at 1.5×.
    @Test("The chosen speed survives being paused")
    func defaultRateIsTheChosenSpeed() {
        let info = fields(rate: 1.5, isPlaying: false)
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.5)
    }

    @Test("Playing reports the real rate")
    func playingRate() {
        let info = fields(rate: 1.5, isPlaying: true)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
    }

    /// A book is not a live stream, and saying so is what gets a scrubber rather
    /// than a spinner.
    @Test("Not a live stream")
    func notLive() {
        #expect(fields()[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
    }

    /// A thirty-hour single-file book otherwise shows the same name on both
    /// lines for its whole length.
    @Test("The chapter becomes the title and the book becomes the album")
    func chapterTakesTheTitleLine() {
        let info = fields(title: "A Hat Full of Sky", chapterTitle: "Chapter 3")

        #expect(info[MPMediaItemPropertyTitle] as? String == "Chapter 3")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "A Hat Full of Sky")
    }

    @Test("With no chapter, the book is both lines")
    func withoutChapter() {
        let info = fields(title: "A Hat Full of Sky", chapterTitle: nil)

        #expect(info[MPMediaItemPropertyTitle] as? String == "A Hat Full of Sky")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "A Hat Full of Sky")
    }

    /// An empty chapter title is the same as none. Track boundaries on a badly
    /// tagged file can produce one, and it would blank the title line.
    @Test("An empty chapter title does not blank the title")
    func emptyChapterTitle() {
        let info = fields(title: "A Hat Full of Sky", chapterTitle: "")
        #expect(info[MPMediaItemPropertyTitle] as? String == "A Hat Full of Sky")
    }

    /// Omitted rather than blank: an empty artist line is a line the card still
    /// reserves room for.
    @Test("A missing author is left out entirely")
    func noAuthor() {
        #expect(fields(author: nil)[MPMediaItemPropertyArtist] == nil)
        #expect(fields(author: "")[MPMediaItemPropertyArtist] == nil)
    }

    @Test("An author is reported as the artist")
    func author() {
        #expect(fields(author: "Terry Pratchett")[MPMediaItemPropertyArtist] as? String
                == "Terry Pratchett")
    }

    @Test("The media type is audio")
    func mediaType() {
        #expect(fields()[MPNowPlayingInfoPropertyMediaType] as? UInt
                == MPNowPlayingInfoMediaType.audio.rawValue)
    }
}

@Suite("Now Playing state")
struct NowPlayingStateTests {

    @Test("Playing and paused map straight across")
    func simpleStates() {
        #expect(NowPlayingFields.playbackState(isPlaying: true, isBuffering: false, isIdle: false)
                == .playing)
        #expect(NowPlayingFields.playbackState(isPlaying: false, isBuffering: false, isIdle: false)
                == .paused)
    }

    /// A stall is not a pause. A card that flips to paused every time a chunk is
    /// slow reads as the app stopping by itself.
    @Test("Buffering still reports as playing")
    func bufferingIsPlaying() {
        #expect(NowPlayingFields.playbackState(isPlaying: false, isBuffering: true, isIdle: false)
                == .playing)
    }

    @Test("Nothing loaded is stopped")
    func idleIsStopped() {
        #expect(NowPlayingFields.playbackState(isPlaying: false, isBuffering: false, isIdle: true)
                == .stopped)
    }

    /// Idle wins over everything: a player with no book is stopped whatever else
    /// the flags say.
    @Test("Idle takes precedence")
    func idleWins() {
        #expect(NowPlayingFields.playbackState(isPlaying: true, isBuffering: true, isIdle: true)
                == .stopped)
    }
}
