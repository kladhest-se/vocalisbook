# Further correctness fixes — 13 November 2026

These changes address the four findings from the follow-up correctness review.

1. **Local server-key collisions:** metadata removal detaches local positions, bookmarks, speed, session references and Plex outbox entries under canonical identities in the same transaction. Caching matching metadata reattaches them. Reused keys with different identities detach the old state before replacing metadata. Legacy orphan rows that cannot be attributed are retained under unresolved keys by migration v14.
2. **Session ownership:** session rows carry the originating installation ID. Ending a session requires the exact process-local active ID and local ownership. Starting a session only closes abandoned sessions from this installation. A newly constructed store cannot end a pre-crash session at today's time or close an imported remote session.
3. **Cloud history clearing:** cancel the old sync engine, ignore late callbacks, await deletion and recreation of the private zone, then clear local rows. An already missing zone permits an idempotent retry. Other errors preserve local history and are shown to the user. A pending-reset marker holds automatic sync/resync after failure or interruption until Clear listening history is retried successfully.
4. **Download lifecycle:** serial scheduling reconciles current/restored tasks before creating new ones. Removal invalidates older scheduled work, cancels matching transfers, and removal of all downloads also cancels orphaned tasks. Store callbacks check attempt identity so a cancelled task cannot overwrite a retry. Attempt-specific file names keep late completions from replacing newer files.

The new tests cover colliding server keys, returning to the original server, portable identity under a new key, changed cached identities, migration of legacy orphans, imported open-session ownership, abandoned local sessions, cloud-reset failure/retry ordering, duplicate/restored downloads, selective/all cancellation and stale callbacks.

Device-level Plex/iCloud delivery, OS suspension and process termination still require the scenarios in the release checklist. Unit tests and unsigned builds do not establish those behaviors. The scope does not add a permanent cloud-erasure barrier against an offline second device later republishing its retained data.


## Validation

`make check` passed: 124 PlexKit tests, 278 Audiobooks tests, 49 Platform/Shared tests and 43 Mac platform tests — **494 total**, including 13 new regressions. The six platform drift groups and iOS/tvOS platform package builds also passed. Unsigned iOS, macOS and tvOS app builds succeeded with Xcode 27.2. No live cloud deletion, authenticated Plex playback or device suspension test was performed.
