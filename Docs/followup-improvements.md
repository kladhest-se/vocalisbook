# Reliability and listening-data improvements — 14 November 2026

## Synchronization

Every Plex upload using one database shares a serial operation queue, including uploads requested by foreground catch-up, pause, completion and retries. A waiting operation takes its snapshot when it starts. Cancellation does not allow another operation to overtake a still-running request. Server filtering occurs before the queue limit, and an old client cannot send the active server's reused book number after a server switch.

Settings now shows pending and failed Plex updates, the most recent successful Plex update, the next retry and retry controls. It also shows pending iCloud rows and the last successful iCloud update. iCloud success timestamps survive relaunch; partial failures remain visible. “Sync with Plex now” clears retry delays without deleting pending payloads. Offline mode still prevents Plex uploads. “Sync with iCloud now” respects the iCloud toggle and can restart an unavailable driver; the existing crash-retry action also starts an actual retry.

Some retained updates wait for their book metadata to be indexed before they can be uploaded. A pending count does not imply data has been lost.

## Full library scans

Only a completed full scan reconciles missing book metadata. Incremental scans, incomplete or changing pagination and cancelled scans do not treat unseen books as deleted. New metadata cached after a scan started is protected. Removing an absent cached book first moves its listening state and pending updates under the recording identity, allowing a matching book to claim them later.

Books with download records remain available as local copies, together with their playback metadata. Automatic scans do not remove their files or download records. Their absent server details are not repeatedly fetched; a later server listing can make them eligible for refresh again. Explicit download-removal controls remain available.

## Actual playback and crash recovery

Listening sessions begin with actual audio playback, rather than the initial Play request. Buffering, pause, failure and stop end the active listening interval. Duplicate Play requests do not replace an active session. Completion checks the exact final owned player item instead of relying on a queue length that may already have changed.

Confirmed playback checkpoints are saved approximately every five seconds while playback callbacks arrive. At startup, sessions owned by this installation recover only through their saved checkpoint. Older sessions without a checkpoint recover at zero length; imported sessions owned by other installations are untouched. Playback since the most recent checkpoint can still be lost if the process is killed. Native buffering, interruptions and background execution require device validation.

Statistics union overlapping closed intervals before splitting them across local calendar days. Simultaneous recordings on multiple devices therefore count once. Source sessions are retained; expanded day details explain when individual session durations overlap. Calendar, daylight-saving and week-boundary behavior from the earlier daily-statistics fix remains in place.

Migration v17 adds nullable checkpoint fields and a small sync-health table. It preserves existing rows and does not invent historical checkpoints.

## Listening backups

On iPhone, iPad and Mac, open **Settings → Data → Export listening backup…**. Choose a destination using the native file picker. The JSON file contains progress, completion, bookmarks including deletion markers, session history and per-book speed. It also includes retained identity-owned data and supported incoming records waiting for their books. Audio files, covers, Plex tokens, account credentials and database files are excluded. Listening backups are not encrypted.

Use **Import listening backup…** to select a file. VocalisBook validates it and shows the number of book records, bookmarks and sessions before offering **Merge backup**. Nothing is changed before that confirmation. Playback pauses during the merge. The import runs in one transaction, retains newer local data and marks accepted changes for the normal sync pipelines. It does not replace the database or restore account settings.

Recording identities resolve the restored data; numeric rating keys from the file never choose a book on another server. Missing books retain their data under their identity until matching metadata returns. Legacy unresolved data remains separate and is not guessed onto a book. Re-importing the same backup does not duplicate sessions or bookmarks. An open backed-up session restores as closed at its confirmed checkpoint, without counting the time after export.

The supported format is `VocalisBookListeningBackup`, version 1, with a maximum of 50 MB and 100,000 counted book/bookmark/session records. Invalid, unsupported and oversized files are rejected before changes are written. These backups merge listening state; they are not full application or audio-library images. Apple TV has no document import/export interface: create or restore a backup on iPhone, iPad or Mac and use iCloud to carry the restored listening state to Apple TV.

## Verification

Offline regression coverage includes independently created upload workers, cancellation, server switches, complete/incomplete scans, retained audio and identity recovery, checkpoints and startup recovery, overlapping sessions, portable backups, repeated imports, stale local conflicts, cloud-first records, unresolved data, malformed backups, persistent sync health and data-preserving upgrades. All databases and cache directories used by tests are temporary. No production account or user database is used.

Validation passed: **563 package tests** (133 PlexKit, 331 Audiobooks, 56 Platform/Shared and 43 Mac platform), **69 offline release-tool tests**, platform consistency checks and unsigned iOS/macOS/tvOS app builds. This includes 34 new package tests in this follow-up. Live Plex/iCloud delivery, signed-device playback and native file-picker round trips remain device checks. No production accounts, user databases or audio files were changed during validation.
