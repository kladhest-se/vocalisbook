# CloudKit setup and wire schema

Cloud sync is optional. Package tests use in-memory SQLite and local CKRecord objects; they require no Apple account. Real sync needs an Apple Developer team with the required iCloud and push capabilities, a signed app, and an iCloud account on each test device.

## Configure a development build

1. Register your own bundle identifier for the app under your team. The checked-in XcodeGen prefix is `se.kladhest.vocalisbook`; its `VocalisBook` target generates `se.kladhest.vocalisbook.VocalisBook`. Verify the effective `PRODUCT_BUNDLE_IDENTIFIER` in Xcode Build Settings rather than assuming the prefix is the complete App ID. Change each platform's prefix or set the target identifier explicitly for your development build.
2. Register an iCloud container for your team and enable CloudKit and Push Notifications on the app identifiers. Use the same container for all three platforms if they should sync together.
3. Update the container in each app's `Sources/VocalisBook.entitlements` and in each `VocalisBookApp.swift` call to `CloudSyncDriver(..., containerIdentifier:)`. The production identifier currently used by this source is `iCloud.se.kladhest.vocalisbook`. Your own team cannot assume access to it.
4. Regenerate the projects, select your team, and allow Xcode to provision development profiles matching the capabilities. Preserve the iOS/tvOS remote-notification background mode and development push entitlement. Xcode supplies the distribution entitlement when signing for release.
5. Sign in to iCloud on a development device and leave the in-app iCloud setting enabled. First run uses the Development environment. Create sample progress, a bookmark and a listening session to populate the schema. Check the private database in CloudKit Console.
6. Before TestFlight or App Store distribution, deploy the schema to Production in CloudKit Console. Development data itself does not move to Production. Check a distribution build with two devices on the same iCloud account.

App IDs, signing profiles, capabilities and production schema deployment are account operations; this repository does not perform them automatically.

## Database and records

The driver uses the **private** CloudKit database and a custom zone named `VocalisBook`. Record names are `<recordType>-<id>`. Record types and field names are wire identifiers and must not be renamed without a compatibility plan.

All four record types include `revision` (Int64) and `isDeleted` (Int64, 0 or 1).

| Type | Record id | Fields |
| --- | --- | --- |
| `Progress` | Canonical book identity | `absoluteMs` Int64, `changedAt` Date/Time, optional `finishedAt` Date/Time |
| `Bookmark` | Bookmark UUID | `bookIdentity` String (optional for legacy records), `bookRatingKey` String (legacy compatibility), `absoluteMs` Int64, `createdAt` Date/Time, optional `label` String and `deletedAt` Date/Time |
| `BookSettings` | Canonical book identity | optional `rate` Double |
| `ListeningSession` | Session UUID | `bookIdentity` String, `bookRatingKey` String (legacy compatibility), `startedAt` Date/Time, `startMs` Int64, optional `endedAt` Date/Time, `endMs` Int64 and `rate` Double; `originDeviceID` String on current clients (absent on legacy records) |

Snapshots clear absent optional fields owned by this version. Unknown fields are preserved for forward compatibility. Numeric types are determined by the schema, including rates of exactly 1.0 and 2.0. The acknowledgement uses the revision the server actually saved, so editing during a save remains pending.

Portable book identities come from VocalisMeta. The fallback is `plex:<server machine identifier>:<rating key>` and only resolves within that server. Legacy records that contain only a raw rating key have no server information; they remain readable for compatibility but cannot provide cross-server identity guarantees. A supplied canonical identity always takes precedence over a legacy key.

Incoming progress waits in `cloud_progress` when its book is missing. Bookmark, session and settings snapshots wait in `cloud_pending_record` and attach atomically when their book is cached. User-data snapshots are retained until resolved or explicitly cleared. Schema migration v13 adds this inbox without rewriting existing user rows. It cannot reconstruct identities already discarded by an older client; a full fetch from iCloud can recover those records if the cloud copy still contains the identity.

Progress conflicts compare the last-change timestamp (then revision for equal timestamps). Bookmarks, settings and sessions compare revisions. Clock skew can affect progress ordering; using portable identities does not eliminate that limitation. A bookmark deletion is a tombstone rather than an ordinary missing row.

## Verify real sync

- On device A, change a label, pause at a new position and select 1×, 1.5× and 2×. Confirm all values on B.
- Finish a book, then reset its progress; B must show it unfinished.
- Remove a bookmark label; B must show no old label.
- Edit while a save is underway; the final edit must reach B.
- Start a fresh install while library fetching is slow; arriving bookmarks/history must attach after metadata arrives.
- Point the devices at different servers with colliding rating keys. Per-server fallbacks must not share progress; a common VocalisMeta identity should share it.

Use Settings' Sent/Received counters and error text, plus Console categories `cloud` and `push`. Test device suspension and notification delivery separately; an unsigned build or a simulator without iCloud cannot prove either.

## Local ownership and confirmed resets

Migration v14 adds a local installation identifier and `origin_device_id` on listening sessions. Outgoing session records carry `originDeviceID`; importing a legacy session assigns remote ownership rather than guessing that it belongs to this device. End-session updates require the active session ID and this installation's owner ID.

Clearing cloud history cancels the old engine, ignores its late callbacks, awaits private-zone deletion and recreation, and only then clears local listening data. Missing-zone errors on delete are accepted so a partially completed reset can be retried. Other failures propagate to the app; the pending-reset flag holds automatic sync/resync until a successful user retry. Zone deletion on one device does not guarantee that an offline second device will never republish retained records.
