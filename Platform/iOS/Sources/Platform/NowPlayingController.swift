import Foundation
import MediaPlayer
import Audiobooks

/// Wires the Lock Screen, Control Centre and headphone controls to the player.
///
/// Everything reported here is book-level, not track-level: the Lock Screen
/// scrubber shows position within the whole book, which is the only figure a
/// listener cares about and the one Plex's own client gets wrong.
@MainActor
public final class NowPlayingController {
    private let player: AudiobookPlayer
    private var artworkTask: Task<Void, Never>?
    private var currentTitle: String?

    public init(player: AudiobookPlayer) {
        self.player = player
        configureCommands()
        // Attached here rather than in the app layer, so nothing has to remember
        // to keep Control Centre in step with playback.
        player.onPlaybackStateChanged = { [weak self] in self?.publishPlaybackState() }
    }

    /// Wraps an action so MediaPlayer can call it from wherever it likes.
    ///
    /// Same trap as the artwork handler: a closure written inside this
    /// `@MainActor` class is inferred to be MainActor-isolated, and MediaPlayer
    /// holds these and invokes them on a queue of its choosing. Remote command
    /// targets are widely observed to arrive on the main thread, but "widely
    /// observed" is what the artwork handler had going for it too, right up
    /// until a crash report said otherwise.
    ///
    /// Written in a `nonisolated` function, so the returned closure carries no
    /// isolation and hops to the main actor itself. `.success` is returned
    /// before the action runs, which is the right answer anyway — the command
    /// was accepted; whether playback then does something is not the system's
    /// question.
    private nonisolated static func command(
        _ action: @escaping @Sendable @MainActor () -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    /// As above, for commands that carry a value. The value is pulled out of the
    /// event synchronously — the event object itself must not outlive the call.
    private nonisolated static func command<Value: Sendable>(
        value: @escaping (MPRemoteCommandEvent) -> Value?,
        _ action: @escaping @Sendable @MainActor (Value) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let value = value(event) else { return .commandFailed }
            Task { @MainActor in action(value) }
            return .success
        }
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        let player = self.player

        center.playCommand.addTarget(handler: Self.command { player.play() })
        center.pauseCommand.addTarget(handler: Self.command { player.pause() })
        center.togglePlayPauseCommand.addTarget(handler: Self.command { player.togglePlayPause() })

        // Skip intervals must be registered here or the system shows 15s
        // regardless of what the app does internally.
        updateSkipIntervals(player.skipIntervalSeconds)
        center.skipForwardCommand.addTarget(handler: Self.command(
            value: { ($0 as? MPSkipIntervalCommandEvent)?.interval },
            { interval in player.skip(bySeconds: Int(interval)) }
        ))
        center.skipBackwardCommand.addTarget(handler: Self.command(
            value: { ($0 as? MPSkipIntervalCommandEvent)?.interval },
            { interval in player.skip(bySeconds: -Int(interval)) }
        ))

        // Next/previous map to chapters rather than tracks. On a multi-file book
        // those coincide; on a single-file m4b, mapping them to tracks would
        // make both buttons dead.
        center.nextTrackCommand.addTarget(handler: Self.command { player.skipToNextChapter() })
        center.previousTrackCommand.addTarget(handler: Self.command { player.skipToPreviousChapter() })

        center.changePlaybackPositionCommand.addTarget(handler: Self.command(
            value: { ($0 as? MPChangePlaybackPositionCommandEvent)?.positionTime },
            { position in player.seek(toAbsoluteMs: Int(position * 1000)) }
        ))

        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        center.changePlaybackRateCommand.addTarget(handler: Self.command(
            value: { ($0 as? MPChangePlaybackRateCommandEvent)?.playbackRate },
            { rate in player.rate = rate }
        ))

        player.onSkipIntervalChanged = { [weak self] seconds in
            self?.updateSkipIntervals(seconds)
        }
    }

    private func updateSkipIntervals(_ seconds: Int) {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: seconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: seconds)]
    }

    /// Call whenever the book, position, or playback state changes.
    public func update(title: String, author: String?, artworkURL: URL?) {
        var info = NowPlayingFields.fields(
            title: title,
            author: author,
            chapterTitle: player.currentChapter?.title,
            durationMs: player.totalDurationMs,
            positionMs: player.absoluteMs,
            rate: player.rate,
            isPlaying: player.state == .playing
        )

        let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo
        if let artwork = existing?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
           currentTitle == title {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        publishPlaybackState()

        if currentTitle != title {
            currentTitle = title
            loadArtwork(from: artworkURL)
        }
    }

    /// Fetches cover art for the Lock Screen.
    ///
    /// This is one of the two documented places the Plex token travels in a
    /// URL query rather than a header: `MediaPlayer` fetches artwork itself and
    /// will not attach custom headers. The URL points only at the user's own
    /// server and must never be logged.
    /// Publishes whether audio is actually playing.
    ///
    /// Required on macOS and tvOS: without `playbackState` the system has the
    /// metadata but no session, so no Now Playing card appears in Control Centre
    /// at all — which is why the tvOS app never showed up there. On iOS the
    /// audio session implies it, so this was invisible on the one platform that
    /// was being tested.
    ///
    /// Elapsed time and rate go with it. The system interpolates between
    /// updates from those two numbers, so they only have to be right whenever
    /// playback changes — not every second.
    public func publishPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(player.absoluteMs) / 1000
        info[MPMediaItemPropertyPlaybackDuration] = Double(player.totalDurationMs) / 1000
        // `0.0` rather than `0`: assigning into `[String: Any]` gives the
        // literal nothing to unify with, so it stays an `Int`. See the note in
        // `NowPlayingFields`.
        info[MPNowPlayingInfoPropertyPlaybackRate] =
            player.state == .playing ? Double(player.rate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(player.rate)
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        MPNowPlayingInfoCenter.default().playbackState = NowPlayingFields.playbackState(
            isPlaying: player.state == .playing,
            isBuffering: player.state == .buffering,
            isIdle: player.state == .idle
        )
    }

    private func loadArtwork(from url: URL?) {
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  self != nil
            else { return }

            guard let artwork = Self.makeArtwork(from: data) else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
        }
    }

    /// Builds the artwork object, deliberately outside this actor.
    ///
    /// `MPMediaItemArtwork` keeps its request handler and calls it later, on its
    /// own `accessQueue`, whenever something asks for a particular size. A
    /// closure written inside this `@MainActor` class is inferred to be
    /// MainActor-isolated, so Swift checks the isolation when MediaPlayer calls
    /// it — off the main queue — and traps:
    ///
    ///     _dispatch_assert_queue_fail
    ///     swift_task_isCurrentExecutorWithFlagsImpl
    ///     closure #1 in closure #1 in NowPlayingController.loadArtwork(from:)
    ///     -[MPMediaItemArtwork jpegDataWithSize:]
    ///
    /// Writing it in a `nonisolated` function makes the closure nonisolated too,
    /// which is the truth: it only reads an image it already holds. The call is
    /// synchronous, so nothing crosses an actor boundary to reach it.
    private nonisolated static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
