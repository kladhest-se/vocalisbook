# Plex progress queue

Local position, finish and restart actions are saved before sending to Plex. The queue coalesces edits by book and action, so offline listening retains the latest position rather than every playback tick.

## Responses during playback

A request carries the entry returned by `SyncStore.pendingOutbox`. Success and failure handling compare its ID, book, action, revision, event timestamp and position with the row still in the queue. A response for a replaced or removed mutation does nothing to the newer row.

A successful response removes only its matching row. It records a clean progress baseline only when the current progress revision, event timestamp and position also match. Continuing playback, finishing a book or restarting it while a request is in flight therefore remains pending, even when its numeric position is unchanged. A late response cannot overwrite a newer successful baseline.

`ProgressSync.drain` shares a serial queue across store values using the same database. It filters by the serving Plex installation before applying the batch limit and sends a snapshot when its turn begins. Cancellation retains queue order. Changes recorded while it runs remain available for the next drain.

## Retry delays

After a failed request, its unchanged entry records `lastAttemptAt`. Retry delay is `min(2^attempts, 3600)` seconds: 2, 4, 8 seconds and so on, capped at one hour. Each failure restarts the delay from that failed request, regardless of how long ago the user made the edit. A replacement edit resets attempts, error and retry timestamp and is immediately eligible.

Event time (`recordedAt`) stays separate. Queue ordering and the existing grace period for missing timelines still use the original edit time. Ordinary connection failures are retained for retry.

## Database upgrade

Migration `v16_plex_outbox_attempt_time` adds the nullable `last_attempt_at` column. Existing failed entries begin their current retry delay at upgrade because older databases did not record attempt time. Entries with no failures remain immediately eligible. IDs, payloads, revisions, errors, attempt counts and original event timestamps are preserved; no queued updates or listening records are deleted.

## Verification

Regression tests cover newer coalesced positions, unchanged offsets with newer revisions, completion/reset changes, reordered and duplicate responses, stale failures, old offline events, repeated exponential delays and the one-hour cap, replacement edits and upgrading a populated v15 queue. An HTTP fixture advances playback before returning a response and verifies that the next drain sends the newer position. Tests use temporary databases and no live Plex account.

Validation passed: **516 package tests** (127 PlexKit, 293 Audiobooks, 53 Platform/Shared and 43 Mac platform), platform drift checks and unsigned iOS/macOS/tvOS app builds. This includes 11 new Plex queue tests and stronger existing queue assertions. Live server delivery remains a device-level check.
