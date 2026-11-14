# Listening data, recovery and downloads

Plex stores per-file playback positions. VocalisBook also keeps book positions, bookmarks, listening sessions and per-book speed locally; optional iCloud sync shares that listening state. Plex does not back up your bookmarks or listening history for you.

On iPhone/iPad and Mac the database lives in Application Support, under `VocalisBook/vocalisbook.sqlite`. It is durable across launches and excluded from automatic backup by the app. Downloaded audio is also excluded from backup. On Apple TV the database is a purgeable cache; Plex and iCloud must rebuild it if the system removes it. Do not rely on Apple TV as the sole copy of listening state.

| Action | What it does | What it keeps |
| --- | --- | --- |
| Disable iCloud sync | Stops this device's cloud syncing. Already uploaded records remain in iCloud. | Local data, downloads, Plex positions and other devices' cloud data |
| Re-enable iCloud sync | Resumes cloud syncing and merges incoming records with local edits using the existing conflict rules. | All local listening records, library and downloads |
| Clear local cache | Stops playback, removes downloads and local library/listening rows, then refreshes Plex and, if enabled and available, iCloud. | Sign-in and the remote Plex/iCloud copies |
| Clear listening history | Removes local listening state, bookmarks, per-book speed and deferred cloud records. When iCloud sync is enabled it first confirms deletion/recreation of the shared cloud zone, then removes local listening data. | Library, downloaded audio and Plex's own positions |
| Sign out | Removes credentials and cached Plex metadata. | Local listening records remain under canonical book identities and downloads may remain for reuse; signing out is not a secure erase or an account-data deletion |

**Before a clear-local-cache action, let unsynced edits reach iCloud.** Data that exists only on this device is lost when its local rows are cleared. An enabled iCloud toggle does not guarantee that the last upload succeeded. Check account availability and sync status first. Re-enabling sync preserves offline-only history/bookmarks and queues pending local changes; it no longer clears local rows before checking account availability.

Clearing local cache deletes downloaded audio; those files must be downloaded again manually. Metadata refresh does not redownload every audiobook. Clearing history leaves Plex positions alone, so opening a book can recover the position Plex last saw. Cloud clearing stops the sync engine and confirms remote zone deletion and recreation before removing local listening rows. If either network step fails, local data is kept and an error asks you to retry **Clear listening history**. A pending-reset marker survives relaunch; automatic sync/resync stays stopped until the retry finishes. This prevents old local rows from immediately repopulating the zone. Offline devices retaining their own state can still contribute records later: this is not a permanent account-wide deletion barrier.

Use Settings → Data → Export listening backup… on iPhone/iPad or Mac for a portable listening-state backup. Import listening backup… validates and previews a merge that preserves newer local edits. Audio and account credentials are excluded. See [backup and merge instructions](followup-improvements.md). There is no undo or guaranteed automatic backup. For a manual desktop backup, quit VocalisBook first and copy the entire `VocalisBook` Application Support directory, retaining any SQLite `-wal` and `-shm` files alongside the database. Do not copy only a live database file, and never edit the production database while the app is running. This manual filesystem procedure is for the Mac; it does not provide a supported iOS/tvOS restore workflow.

If the local store fails to open, retain the database and the error message. Try a normal restart before clearing data. Report the app/platform version, whether iCloud is enabled, and relevant error text; do not share Plex tokens or the database publicly.

## Offline download failures

The app accepts complete HTTP 200 audio/binary responses and rejects error statuses, login pages and common error documents. A 401/403 usually needs a fresh sign-in or permission check; a 404 can mean the server file moved; a 500 is a server failure. Failed transfers should show an error rather than a downloaded check mark. Retry after resolving the cause.

Wi-Fi-only/expensive-network preferences apply to the background session created at launch; restart the app after changing them. For a real iPhone background check, start a download, put the app in the background, let the transfer finish, and reopen it. Also test a system-terminated app. Force-quitting an app is a separate OS behavior and is not a promise that background transfers continue.

## Server changes and retained listening state

Before discarding cached server metadata, the database moves positions, bookmarks, speed settings, session references and pending Plex writes under the book's canonical identity. They reattach only when that identity (or the same server's fallback identity) is cached again. A different server reusing the same numeric rating key cannot claim them. The same portable VocalisMeta book can recover local progress under a different rating key without an iCloud round trip.

Migration v14 retains legacy listening rows whose metadata is already missing under `@unresolved:` keys. No trustworthy identity can be inferred for those rows, so they are preserved for recovery rather than guessed onto another book. Correct identities lost before this upgrade cannot be reconstructed automatically. Do not delete a database containing such records if they are your only copy.

Session rows now carry an originating installation ID; pausing a local session closes only that session. A fresh process cannot end an abandoned session at the current time and count the entire downtime as listening. The next local session closes abandoned sessions from this installation at zero length. Keep the installation identifier private to its own database; copying a live database between devices is not a supported multi-device setup.

Removing downloads now cancels matching background tasks, including restored tasks, and a repeated request reuses active transfers. Removing all downloads also cancels orphaned restored transfers. Late callbacks from a cancelled attempt cannot mark a newer retry failed or complete.

## Server-scoped audio upgrade (v15)

New audio keys include a hash of the Plex server identity as well as the part's staleness information. Identical part numbers, timestamps or sizes on different servers cannot select the same download.

Older download records did not record trustworthy server ownership. The upgrade keeps their files, relative paths, byte counts, tracks and chapters, but marks the downloads as requiring verification and cached timelines as incomplete. It does not erase them. Such downloads show a failure/re-download explanation and cannot be used for playback. Automatic stale/orphan cleanup retains their file references; explicit Remove download / Remove all actions can still remove them at your request. Their retained bytes remain included in storage accounting.

Connect to Plex and reopen or retry loading the book to obtain a complete timeline. Download it again to create a server-scoped offline copy. The older retained copy can then be removed using the download controls. Metadata refresh alone does not prove that an older file came from the correct server.

If a track lacks duration, a playable part or a file URL, the whole book is treated as incomplete rather than dropping that track and shifting all later positions. Existing valid cached timelines and progress are retained when an incomplete refresh fails. The book screen explains the missing metadata and offers Retry loading book.
