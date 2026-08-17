import Foundation
import PlexKit

/// Tells the server what this client is doing, while it is doing it.
///
/// Plex's dashboard and its "now playing" list are built from `/:/timeline`
/// heartbeats, not from stored progress — a client that only reports when it
/// pauses has a correct position and is invisible while playing. That is why
/// VocalisBook never appeared in the web dashboard.
///
/// Separate from `ProgressSync`, which is about *persisting* a position and
/// queues to an outbox so it survives being offline. This is presence: it is
/// worthless a minute later, so a failed heartbeat is dropped rather than
/// retried.
///
/// `PlaybackState` is nested inside `PlexServerClient`, so it needs qualifying
/// here — it resolves bare only inside that type.
@MainActor
public final class NowPlayingReporter {

    /// Plex treats a client as gone after about 30 seconds without a
    /// heartbeat; ten gives room for one to fail without the session
    /// disappearing from the dashboard.
    private static let interval: Duration = .seconds(10)

    private var task: Task<Void, Never>?
    private var lastReportedState: PlexServerClient.PlaybackState?

    public init() {}

    /// Begins reporting, replacing any previous session.
    public func start(
        client: PlexServerClient,
        segment: @escaping @MainActor () -> (trackRatingKey: String, trackKey: String, offsetMs: Int, durationMs: Int)?,
        state: @escaping @MainActor () -> PlexServerClient.PlaybackState
    ) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.beat(client: client, segment: segment, state: state)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Reports once, immediately — for a pause or a stop, where waiting up to
    /// ten seconds would leave the dashboard showing playback that has ended.
    public func reportNow(
        client: PlexServerClient,
        segment: @MainActor () -> (trackRatingKey: String, trackKey: String, offsetMs: Int, durationMs: Int)?,
        state: PlexServerClient.PlaybackState
    ) {
        guard let current = segment() else { return }
        Task {
            try? await client.reportTimeline(
                trackRatingKey: current.trackRatingKey,
                trackKey: current.trackKey,
                state: state,
                offsetMs: current.offsetMs,
                durationMs: current.durationMs
            )
        }
        lastReportedState = state
    }

    /// Stops reporting and tells the server the session has ended.
    ///
    /// Without the final `stopped`, the dashboard shows a paused session
    /// indefinitely — the server has no other way to know the client is gone.
    public func stop(
        client: PlexServerClient?,
        segment: @MainActor () -> (trackRatingKey: String, trackKey: String, offsetMs: Int, durationMs: Int)?
    ) {
        task?.cancel()
        task = nil
        guard let client else { return }
        reportNow(client: client, segment: segment, state: .stopped)
    }

    private func beat(
        client: PlexServerClient,
        segment: @MainActor () -> (trackRatingKey: String, trackKey: String, offsetMs: Int, durationMs: Int)?,
        state: @MainActor () -> PlexServerClient.PlaybackState
    ) async {
        guard let current = segment() else { return }
        let now = state()
        // Paused and stopped are reported once rather than every ten seconds:
        // the dashboard keeps showing them, and repeating them is noise on the
        // server's log.
        //
        // Stopped matters more than paused. A caller that has nothing playing
        // can say so through the state closure, and the heartbeat sends it once
        // and then goes quiet — without the heartbeat having to be torn down and
        // rebuilt, which is what a `stop` here would mean for a client that will
        // play something else in a minute.
        if now == lastReportedState, now == .paused || now == .stopped { return }

        try? await client.reportTimeline(
            trackRatingKey: current.trackRatingKey,
            trackKey: current.trackKey,
            state: now,
            offsetMs: current.offsetMs,
            durationMs: current.durationMs
        )
        lastReportedState = now
    }
}
