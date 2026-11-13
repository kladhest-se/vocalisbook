# Audit fixes — 13 November 2026

The changes below address all seven code findings from the source audit of `vocalisbook.zip`. The original archive is preserved; the edited project is in `audit-source/` in the audit workspace. A clean replacement source archive and an applyable patch are supplied beside that folder.

| Finding | Change | Regression coverage |
| --- | --- | --- |
| 1. Saved acknowledgements clear newer edits | Driver acknowledges the revision in the actual saved CKRecord and queues remaining/newer pending work | Driver-boundary test changes a bookmark during a save and verifies it stays pending |
| 2. Removed fields survive in iCloud | Mapper clears owned optional fields while preserving unknown future fields; incoming bookmark snapshots clear absent labels | Finished date reset and empty-label cloud/store round trips |
| 3. Server identities cross-match | Fallback resolution joins the library section and matches the server; canonical identities never fall back to unrelated raw keys | Two servers with a colliding rating key, including portable-GUID upgrades |
| 4. HTTP errors become downloads | Validate HTTP status and reject known login/error MIME types before moving files or recording completion | HTTP 401/403/404/500, incomplete/empty responses, login/error documents, audio and binary responses |
| 5. Whole-number speeds decode incorrectly | Rate fields decode according to schema before generic NSNumber bridging | 1.0, 2.0 and 1.5 CKRecord values |
| 6. Background download completion is incomplete | App delegate retains system completion, reconnects a background-only launch immediately, reuses that session in the app model, and completes after synchronous database commits | Completion ordering and unknown-session tests; iOS/Mac compilation. Actual suspension/system-relaunch remains a device check |
| 7. Early cloud records lose identities | v13 inbox retains full canonical bookmark/session/settings snapshots and attaches them atomically during library caching | Cloud-first/library-second import, older held updates, deferred deletions, both inbox purges, migration from existing data |

## Documentation and tooling

Added build/toolchain/simulator instructions, a CloudKit schema and contributor-team setup guide, data-retention/recovery guidance, contribution instructions, a release checklist, included platform drift verification and a GitHub Actions workflow. Corrected the stale iOS project instruction, missing external-tool references and inaccurate conflict-rule comments. Added the official GPL v3 license text, a GPL-3.0-or-later notice and the GRDB MIT license notice.

## Verification

- PlexKit: 124 tests passed.
- Audiobooks: 272 tests passed, including migration and inbox regressions.
- Platform/Shared: 42 tests passed, including cloud and download boundary regressions.
- Mac platform: 43 tests passed in an unrestricted test run.
- Total: **481 package tests passed** (parameterized test cases are additional invocations).
- Unsigned app builds: **iOS, macOS and tvOS succeeded** with Xcode 27.2.
- Platform drift: six groups passed; a temporary divergent fixture was correctly rejected.
- Website PHP syntax and workflow YAML syntax passed; local links in the new documentation were checked.
- The new `make check` command is also verified as a combined entry point; see final workspace logs for its output.

The Mac MIME-type tests require access to the system type registry. A restricted run could not resolve MPEG's type, while the unrestricted runs passed; this was an environment restriction rather than a source change. Xcode emitted a nonfatal AppIntents SSU archive diagnostic during the first unsigned iOS simulator build, despite reporting BUILD SUCCEEDED; signed-device Siri behavior remains part of release validation.

## Remaining release verification

No live Plex or iCloud account was used. Background execution, real cloud delivery, signed-device playback, App Store submission and remote CI execution are not established by package tests or unsigned builds. Current authenticated-demo screenshots, actual published store URLs, signing/capability setup and Production schema deployment remain explicitly tracked in [the release checklist](release-checklist.md). They require the corresponding assets/accounts and are not replaced with invented content.

Existing data that an old version already synced incorrectly cannot always be reconstructed locally. A resync can recover cloud records only if their correct identity/fields still exist remotely; keep backups and follow [data recovery](data-recovery.md) before clearing local state.
