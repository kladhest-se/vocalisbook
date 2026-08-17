import Foundation
import AVFoundation
import Audiobooks
import PlatformShared

/// The audio engine.
///
/// Everything it exposes is in book-absolute milliseconds. Nothing above this
/// class knows that a book is made of tracks — that translation happens here
/// and in `BookTimeline`, and nowhere else.
@MainActor
@Observable
public final class AudiobookPlayer {

    public enum State: Equatable, Sendable {
        case idle
        case buffering
        case playing
        case paused
    }

    public private(set) var state: State = .idle
    public private(set) var absoluteMs: Int = 0
    public private(set) var timeline: BookTimeline?
    public private(set) var currentChapter: Chapter?
    public private(set) var bookRatingKey: String?

    public var rate: Float = 1.0 {
        didSet {
            applyRate()
            // Rate is half of how the system interpolates elapsed time.
            onPlaybackStateChanged?()
        }
    }

    /// Skip interval for the in-app and Lock Screen controls.
    public var skipIntervalSeconds: Int = 30 {
        didSet { onSkipIntervalChanged?(skipIntervalSeconds) }
    }

    public var onSkipIntervalChanged: ((Int) -> Void)?
    /// Called whenever a position should be persisted. The player does not
    /// touch the database itself — it has no opinion about storage, which keeps
    /// it testable and keeps the write policy in one place.
    public var onPositionChanged: ((String, Int) -> Void)?
    public var onFinished: ((String) -> Void)?

    /// Called when playback stops for any reason the listener caused.
    ///
    /// The moment to push progress to Plex. Waiting for the next library refresh
    /// means a position sits on one device while another starts the same book
    /// from zero — which is exactly what happened between the phone and the Mac.
    public var onPaused: (() -> Void)?

    /// Called when playback begins, with the book and where it began.
    ///
    /// Paired with `onPaused` to bracket a listening session. Fires on resume as
    /// well as on first play — each stretch of listening is its own session, and
    /// stitching them back together is the history screen's job.
    public var onStarted: ((String, Int) -> Void)?

    /// Called when playback is stopped rather than paused.
    ///
    /// Distinct from `onPaused` because the two mean different things to the
    /// server: a pause leaves a session open — which is why the Plex dashboard
    /// fills with paused VocalisBook sessions that nobody is listening to — and a
    /// stop ends it.
    public var onStopped: (() -> Void)?

    /// Called whenever playback state or position changes in a way the system's
    /// Now Playing card should know about: play, pause, seek, rate.
    ///
    /// `NowPlayingController` attaches to this itself, so nothing in the app
    /// layer has to remember to keep Control Centre in step.
    public var onPlaybackStateChanged: (() -> Void)?

    /// Why playback stopped, when it stopped for a reason worth saying.
    ///
    /// A player that fails silently is indistinguishable from one that is
    /// ignoring you, which is what a downloaded book did for as long as its
    /// files were stored under an extension AVFoundation could not read.
    public private(set) var failure: String?

    private let player = AVQueuePlayer()
    private var statusObservation: NSKeyValueObservation?

    /// Holds the things that must be handed back when this player goes away.
    ///
    /// They cannot be cleaned up in `AudiobookPlayer.deinit`: this class is
    /// `@MainActor`, which makes its `deinit` nonisolated, and a nonisolated
    /// `deinit` may not touch main-actor-isolated stored properties. Swift 6
    /// rejects it outright.
    ///
    /// So the registrations live in an object with no isolation of its own,
    /// whose `deinit` is free to unregister them. It is owned by the player, so
    /// it dies at the same moment and the timing is unchanged.
    private final class Registrations {
        let player: AVQueuePlayer
        var timeObserver: Any?
        var notificationTokens: [any NSObjectProtocol] = []

        init(player: AVQueuePlayer) { self.player = player }

        deinit {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    private let registrations: Registrations

    private var segmentURLs: [Int: URL] = [:]
    /// The items currently in the queue, and which segment the first of them is.
    ///
    /// Kept so the playing segment can be worked out on the main actor from
    /// `player.currentItem`, rather than by observing `currentItem` with KVO —
    /// see `observePlayer()` for why that is not safe here.
    private var queuedItems: [AVPlayerItem] = []
    private var queueBaseIndex = 0
    private var currentSegmentIndex = 0
    private var lastPersistedMs = 0
    private var pausedAt: Date?
    private var sleepTimerTask: Task<Void, Never>?
    private let session = AudioSessionConfigurator()

    public init() {
        registrations = Registrations(player: player)
        player.actionAtItemEnd = .advance
        // Speech at 1.5x and above sounds wrong under `.spectral`; `.timeDomain`
        // is the algorithm designed for voice.
        player.automaticallyWaitsToMinimizeStalling = true
        observePlayer()
        observeSession()
    }

    // MARK: - Loading

    /// Loads a book and seeks to a position.
    ///
    /// `urlForSegment` lets the caller return a local file when the track has
    /// been downloaded and a stream URL otherwise, so switching between the two
    /// needs no change here.
    public func load(
        timeline: BookTimeline,
        startingAt absoluteMs: Int,
        rate: Float = 1.0,
        urlForSegment: (BookTimeline.Segment) -> URL
    ) {
        guard timeline.isComplete else { return }

        self.timeline = timeline
        self.bookRatingKey = timeline.bookRatingKey
        self.rate = rate
        self.absoluteMs = absoluteMs
        self.lastPersistedMs = absoluteMs

        segmentURLs = Dictionary(
            uniqueKeysWithValues: timeline.segments.enumerated().map {
                ($0.offset, urlForSegment($0.element))
            }
        )

        let position = timeline.locate(absoluteMs: absoluteMs)
            ?? BookTimeline.Position(segmentIndex: 0, offsetInSegmentMs: 0, absoluteMs: 0)
        rebuildQueue(from: position.segmentIndex, offsetMs: position.offsetInSegmentMs)
        updateChapter()
    }

    /// Replaces the queue starting at a given segment.
    ///
    /// `AVQueuePlayer` only advances forward, so a seek to an earlier track
    /// cannot be done by seeking — the queue has to be rebuilt from that point.
    /// Every later segment is enqueued at the same time so the player handles
    /// transitions itself; swapping items at each boundary produces an audible
    /// gap.
    private func rebuildQueue(from segmentIndex: Int, offsetMs: Int) {
        guard let timeline else { return }
        player.removeAllItems()
        currentSegmentIndex = segmentIndex
        queueBaseIndex = segmentIndex
        queuedItems = []

        for index in segmentIndex..<timeline.segments.count {
            guard let url = segmentURLs[index] else { continue }
            let asset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .timeDomain
            player.insert(item, after: player.items().last)
            queuedItems.append(item)
        }

        if offsetMs > 0, let first = player.items().first {
            first.seek(to: CMTime(value: CMTimeValue(offsetMs), timescale: 1000)) { _ in }
        }
    }

    // MARK: - Transport

    /// Asked before playback starts, and able to refuse.
    ///
    /// The transport buttons in the app can be guarded one by one, and were. The
    /// Lock Screen, the headphone button and the media keys cannot: they are
    /// `MPRemoteCommandCenter` targets that call this type directly and know
    /// nothing about the app's modes.
    ///
    /// So the gate lives here, where every path passes through. Nil means no
    /// gate, which is what the television sets — it has no offline mode and no
    /// downloads to have one with.
    public var canStartPlayback: (@MainActor () -> Bool)?

    public func play() {
        // Before anything, including activating the audio session: a refusal
        // that had already taken the session would leave this app holding it
        // with nothing playing.
        if let canStartPlayback, !canStartPlayback() { return }

        failure = nil
        try? session.activate()

        // Rebuilt if stopping released it.
        //
        // `stop` empties the queue and keeps the book, so this is the moment the
        // queue has to come back — from the timeline and the position, both of
        // which stop left alone. Without this, play after stop is a call to an
        // `AVQueuePlayer` with no items: no sound, no error, no clue.
        if player.currentItem == nil, let timeline,
           let position = timeline.locate(absoluteMs: absoluteMs) {
            rebuildQueue(from: position.segmentIndex, offsetMs: position.offsetInSegmentMs)
        }

        applySmartRewind()
        player.play()
        applyRate()
        state = .playing
        pausedAt = nil
        if let key = bookRatingKey {
            onStarted?(key, absoluteMs)
        }
        onPlaybackStateChanged?()
    }

    /// Ends playback, rather than suspending it.
    ///
    /// Pause keeps the book loaded and the session open on the server. That is
    /// right for a pause and wrong for finishing with a book: the Plex dashboard
    /// shows a paused session indefinitely, and the app has no way to say "I am
    /// done" short of quitting.
    ///
    /// The position is written first. Stopping is not abandoning — somebody who
    /// stops halfway expects to resume there.
    public func stop() {
        persistPosition(force: true)

        // Idle first, before the queue is touched.
        //
        // `tick` ignores an idle player, and that is what stops a late observer
        // moving the position — but only if it is already idle when the queue
        // comes apart. Setting it afterwards leaves exactly the window this is
        // meant to close.
        state = .idle

        player.pause()

        // `removeAllItems`, not `replaceCurrentItem(with: nil)`.
        //
        // This is a queue player, and removing its current item makes it
        // *advance to the next one* — so tearing the queue down one item at a
        // time walks forward through the book. The periodic observer then read
        // the new item and recomputed the position as the start of track two:
        // stop at two seconds, and the player came back at one hour nineteen,
        // which is exactly the length of track one.
        //
        // Emptying the queue leaves nothing to advance to.
        player.removeAllItems()

        // `onStopped` tells Plex the session ended, and what it sends is a
        // timeline for the current track — which the app works out from
        // `timeline` and `absoluteMs`. Both survive, so the order no longer
        // matters, but it stays first because that is when it is true.
        onStopped?()

        // The book stays loaded, and that is the difference from what this used
        // to do.
        //
        // Stopping cleared `bookRatingKey`, `timeline` and `absoluteMs`. The
        // book was still on screen, so the player showed a position of nothing
        // out of a book of no length — a scrubber pinned to the end reading
        // "-0:00" — and pressing play called `play()` on a queue with no items,
        // which does nothing at all. Somebody who stopped a book lost their
        // place and their transport in one press.
        //
        // Stop and pause differ in one way only: stop ends the session on the
        // server and closes the listening session here, pause leaves both open.
        // Neither is a reason to forget where somebody is.
        //
        // The queue is released, because holding an `AVPlayerItem` for a book
        // nobody is listening to is the thing stop is *for*. `play()` rebuilds
        // it from the timeline and the position, which are still here.
        pausedAt = nil

        onPlaybackStateChanged?()
    }

    public func pause() {
        player.pause()
        state = .paused
        pausedAt = Date()
        persistPosition(force: true)
        onPaused?()
        onPlaybackStateChanged?()
    }

    public func togglePlayPause() {
        state == .playing ? pause() : play()
    }

    public func seek(toAbsoluteMs target: Int) {
        guard let timeline, let position = timeline.locate(absoluteMs: target) else { return }

        switch PlaybackRules.seekPlan(
            toSegment: position.segmentIndex,
            currentSegment: currentSegmentIndex,
            hasCurrentItem: player.currentItem != nil
        ) {
        case .seekInPlace:
            player.currentItem?.seek(
                to: CMTime(value: CMTimeValue(position.offsetInSegmentMs), timescale: 1000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in }

        case .rebuild(let from):
            let wasPlaying = state == .playing
            rebuildQueue(from: from, offsetMs: position.offsetInSegmentMs)
            if wasPlaying { player.play(); applyRate() }
        }

        absoluteMs = position.absoluteMs
        updateChapter()
        persistPosition(force: true)
        // The system interpolates the scrubber from the last elapsed time it
        // was given, so a seek it is not told about leaves Control Centre
        // drifting further from the truth with every skip.
        onPlaybackStateChanged?()
    }

    public func skip(bySeconds seconds: Int) {
        seek(toAbsoluteMs: max(0, absoluteMs + seconds * 1000))
    }

    public func skipToNextChapter() {
        guard let timeline,
              let next = timeline.chapters.first(where: { $0.startMs > absoluteMs })
        else { return }
        seek(toAbsoluteMs: next.startMs)
    }

    public func skipToPreviousChapter() {
        guard let timeline else { return }
        // Within the first few seconds of a chapter, "previous" means the one
        // before it. Otherwise it means the start of this one — the behaviour
        // every music player has trained people to expect.
        let threshold = 3_000
        if let current = timeline.chapter(at: absoluteMs), absoluteMs - current.startMs > threshold {
            seek(toAbsoluteMs: current.startMs)
        } else if let previous = timeline.chapters.last(where: { $0.startMs < absoluteMs - threshold }) {
            seek(toAbsoluteMs: previous.startMs)
        } else {
            seek(toAbsoluteMs: 0)
        }
    }

    private func applyRate() {
        guard state == .playing else { return }
        player.rate = rate
    }

    /// Seeks back a little when resuming, scaled to how long the pause was.
    ///
    /// The table itself lives in `SmartRewind` so it can be tested without a
    /// device.
    private func applySmartRewind() {
        guard let pausedAt, state == .paused else { return }
        let rewind = SmartRewind.seconds(forGapSeconds: Date().timeIntervalSince(pausedAt))
        guard rewind > 0 else { return }
        seek(toAbsoluteMs: max(0, absoluteMs - rewind * 1000))
    }

    // MARK: - Sleep timer

    public enum SleepTimer: Equatable, Sendable {
        case duration(TimeInterval)
        case endOfChapter
    }

    public private(set) var sleepTimer: SleepTimer?

    public func setSleepTimer(_ timer: SleepTimer?) {
        sleepTimerTask?.cancel()
        sleepTimer = timer
        guard let timer else { return }

        let deadline: TimeInterval
        switch timer {
        case .duration(let interval):
            deadline = interval
        case .endOfChapter:
            guard let chapter = currentChapter else { return }
            deadline = PlaybackRules.secondsToEndOfChapter(
                chapterEndMs: chapter.endMs,
                positionMs: absoluteMs,
                rate: rate
            )
        }

        // Fade the last stretch rather than cutting: an abrupt stop wakes people
        // up, which defeats the point of the feature. The arithmetic — including
        // a timer shorter than the fade — is in `PlaybackRules`, where it can be
        // tested without waiting for a clock.
        let plan = PlaybackRules.sleepFade(deadline: deadline)

        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(plan.quiet))
            guard !Task.isCancelled else { return }
            await self?.fadeOutAndPause(over: plan.fade)
        }
    }

    private func fadeOutAndPause(over interval: TimeInterval) async {
        let steps = 20
        let startVolume = player.volume
        for step in 0..<steps {
            guard !Task.isCancelled else { player.volume = startVolume; return }
            player.volume = startVolume * Float(steps - step - 1) / Float(steps)
            try? await Task.sleep(for: .seconds(interval / Double(steps)))
        }
        pause()
        player.volume = startVolume
        sleepTimer = nil
    }

    // MARK: - Observation

    private func observePlayer() {
        // `queue: .main` means this block genuinely runs on the main queue, so
        // `assumeIsolated` holds. That is not true of the KVO observations
        // below, which is the whole point of the note there.
        registrations.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }

        // `timeControlStatus` distinguishes a buffering stall from a user pause;
        // `rate` alone cannot, and reporting a stall as "paused" makes the UI
        // lie during a slow connection.
        //
        // AVPlayer delivers KVO on an internal queue, not the main one.
        // `MainActor.assumeIsolated` *traps* when the assumption is false, so
        // the previous version of this crashed the moment a stream started and
        // the status flipped to `.waitingToPlayAtSpecifiedRate`. The new value
        // is an enum and therefore Sendable, so it can be read here and carried
        // to the main actor properly.
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, change in
            guard let status = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.apply(timeControlStatus: status)
            }
        }

        // An item that cannot be loaded says so.
        //
        // Nothing observed this, so a file the player could not open produced
        // exactly nothing: press Resume, no audio, no error, no state change.
        // That is how a wrong filename extension on downloaded files went
        // unnoticed — the failure had no way to reach the screen.
        registrations.notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription
            MainActor.assumeIsolated {
                self?.report(failure: message ?? "This file could not be played.")
            }
        })

        registrations.notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem, item.status == .failed else { return }
                self.report(failure: item.error?.localizedDescription ?? "This file could not be played.")
            }
        })

        // There is deliberately no observation of `currentItem`.
        //
        // Working out which segment is playing needs `player.items()`, and
        // reading that from AVPlayer's internal queue is exactly the race the
        // status observer above was crashing on. The queue only ever advances
        // forward, so `tick` — which does run on the main queue — can work it
        // out by matching `currentItem` against the items it enqueued.
        registrations.notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let timeline = self.timeline else { return }
                // Resync immediately rather than waiting up to half a second
                // for the next tick, so a chapter boundary does not show the
                // previous chapter's title for a beat.
                self.syncCurrentSegment()

                if self.player.items().count <= 1, let key = self.bookRatingKey {
                    self.absoluteMs = timeline.totalDurationMs
                    self.onFinished?(key)
                    self.state = .paused
                }
            }
        })
    }

    /// The last thing that went wrong, for a view to show.
    ///
    /// Cleared on the next successful play rather than on a timer: a message
    /// that disappears on its own is one somebody was reading.
    private func report(failure message: String) {
        self.failure = message
        state = .paused
        onPlaybackStateChanged?()
    }

    private func apply(timeControlStatus status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            state = .playing
        case .waitingToPlayAtSpecifiedRate:
            state = .buffering
        case .paused:
            if state != .idle { state = .paused }
        @unknown default:
            break
        }
    }

    /// Which segment is playing, derived from the item the player is on.
    private func syncCurrentSegment() {
        guard let current = player.currentItem,
              let offset = queuedItems.firstIndex(where: { $0 === current })
        else { return }

        let index = PlaybackRules.segmentIndex(queueBase: queueBaseIndex, offsetInQueue: offset)
        guard index != currentSegmentIndex else { return }
        currentSegmentIndex = index
        updateChapter()
    }

    private func observeSession() {
        // `Notification` is not Sendable, so it cannot cross into the main
        // actor — Swift 6 rejects `MainActor.assumeIsolated { ... note ... }`
        // with "sending 'note' risks causing data races". The values actually
        // needed are plain `UInt` raw values, which are Sendable, so they are
        // pulled out of the notification first and only those cross over.
        registrations.notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt

            MainActor.assumeIsolated {
                guard let self,
                      let typeRaw,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                switch type {
                case .began:
                    self.pause()
                case .ended:
                    let options = optionsRaw.map(AVAudioSession.InterruptionOptions.init) ?? []
                    if options.contains(.shouldResume) { self.play() }
                @unknown default:
                    break
                }
            }
        })

        registrations.notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt

            MainActor.assumeIsolated {
                guard let reasonRaw,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
                // Headphones pulled out. Pausing is not optional here — the
                // alternative is a book playing aloud from someone's pocket.
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        })
    }

    private func tick(_ time: CMTime) {
        // Nothing is playing, so nothing has moved.
        //
        // The observer keeps firing for a moment after the queue is emptied, and
        // a tick with no items behind it describes a player that is not there.
        // Acting on one is how a stopped book acquired a position it had never
        // reached.
        guard state != .idle else { return }

        syncCurrentSegment()
        guard let timeline, currentSegmentIndex < timeline.segments.count else { return }
        let offset = Int(time.seconds * 1000)
        guard let absolute = timeline.absolute(
            segmentIndex: currentSegmentIndex,
            offsetInSegmentMs: offset
        ) else { return }

        absoluteMs = absolute
        updateChapter()
        persistPosition(force: false)
    }

    private func updateChapter() {
        currentChapter = timeline?.chapter(at: absoluteMs)
    }

    /// Persists every ten seconds of movement, plus on demand.
    ///
    /// The threshold is on distance moved rather than wall-clock so a seek
    /// always writes, and so a paused player does not keep writing the same
    /// value.
    private func persistPosition(force: Bool) {
        guard let key = bookRatingKey else { return }
        guard PlaybackRules.shouldPersist(
            positionMs: absoluteMs,
            lastPersistedMs: lastPersistedMs,
            force: force
        ) else { return }

        lastPersistedMs = absoluteMs
        onPositionChanged?(key, absoluteMs)
    }

    // MARK: - Convenience

    public var totalDurationMs: Int { timeline?.totalDurationMs ?? 0 }

    public var progressFraction: Double {
        guard totalDurationMs > 0 else { return 0 }
        return Double(absoluteMs) / Double(totalDurationMs)
    }

    public var isActive: Bool { state == .playing || state == .buffering }
}
