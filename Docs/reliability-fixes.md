# Additional reliability fixes — 13 November 2026

1. **Enable iCloud without deleting local data:** enabling now starts/resumes the driver and merges through the existing store rules. Pending local edits remain intact even when no account is available. Disabling cancels the old engine explicitly.
2. **Server-scoped audio:** cached timeline segments now use filename-safe SHA-256 identities derived from the serving Plex installation and part staleness key. Reused numeric part/book keys on another server cannot find the first server's downloaded file.
3. **Incomplete timelines:** one missing duration/part/file URL, a known track-count mismatch or invalid cached offsets makes the timeline unusable. The cache writer refuses an incomplete update before changing an existing valid timeline. All book screens provide a retry message and disable starting an unavailable timeline.
4. **Startup marker:** a shared tested startup gate clears its flag on account unavailability, cancellation and success, preserving the crash safeguard only for genuinely interrupted processes.

## Non-destructive migration

Migration v15 adds validation flags. Existing download rows, files, relative paths, byte counts, track/chapter metadata and listening state are retained. Unattributable older audio is not served for playback or revived by late background callbacks. Stale/orphan cleanup preserves flagged records, and storage totals include their retained bytes. Users can explicitly remove those downloads using the existing controls. Remove all includes retained files even when their books are no longer cached, and the storage header remains available when only such files remain.

Reopen/retry the book while connected to Plex to validate its timeline, then download a server-scoped copy for offline playback. Existing unscoped files require re-download because the old schema contains no reliable proof of server ownership. See [data recovery](data-recovery.md).

## Verification

Regression coverage includes cross-server audio collisions, file-key stability/invalidation, missing middle-track metadata, preserving a valid timeline after a failed refresh, complete legacy row/path retention, stale/orphan cleanup protection, no-account/cancelled startup, and merging cloud bookmarks with offline-only edits. Live iCloud delivery and OS background execution remain device-level checks; no user accounts or production databases were used in these tests.


Validation passed: **505 package tests** (127 PlexKit, 282 Audiobooks, 53 Platform/Shared, 43 Mac platform), **69 offline release-tool tests**, platform drift checks and unsigned iOS/macOS/tvOS app builds. The migration tests use temporary databases and verify preserved paths/rows before and after automatic cleanup; only the explicit Remove all test removes its fixture rows. Retry loading respects offline mode on iPhone and Mac. No live account, production database or user audio files were modified by validation.
