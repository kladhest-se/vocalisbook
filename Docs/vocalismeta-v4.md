# VocalisMeta contract v4 integration

VocalisBook supports the opt-in v4 contract published by [VocalisMeta revision dc5bdb3](https://github.com/kladhest-se/vocalismeta/tree/dc5bdb307177cf6593380aec75932ad8bda80307), verified against public GitHub HEAD on 14 November 2026. The metadata-agent checkout was not modified. The earlier [v1/v2/v3 integration notes](vocalismeta-integration.md) remain applicable where v4 is absent.

## Enable and inspect

1. Update every VocalisBook installation that reads the library before enabling v4 in the agent. Other readers must also understand or exclude the reserved `VocalisMeta-v4: ` tags; older clients may mistake them for authors.
2. Enable the agent's v4 option deliberately. This app update does not change that setting.
3. Refresh a book through VocalisMeta/Plex, then refresh it in VocalisBook. A detail refresh is needed to accept a complete packet; list responses never apply metadata clears.
4. Open the book's **Metadata sources and recording upgrades** link. **Reload from Plex** obtains fresh Plex metadata; it does not rerun provider matching or refresh the agent itself.

The source screen works from cached data offline. It separates the overall matching source from each field's provenance, availability and date meaning. Manual or locked native Plex values remain authoritative when they differ from the agent snapshot; the screen labels that field's source unverified. Old source information is labeled when a valid current packet is absent or a detail refresh is pending.

## Metadata and artwork behavior

- Metadata and artwork revision tokens are independent. Cover cache keys include the artwork revision and native Plex update timestamp, so replacements at the same thumbnail URL get fresh disk and decoded images. The agent's hash describes its accepted source artwork, not Plex's transcoded image bytes; the client does not compare those bytes to that hash.
- Every accepted full packet is processed, including health/status changes with unchanged tokens. List responses schedule detail refresh for changed packets or malformed v4 tags as well as native timestamp changes.
- Unknown or unavailable fields retain cached values when native values are absent. Missing, disabled or corrupt packets do not manufacture clears. A deliberate clear removes only its metadata projection; it never clears listening data or independently valid credits.
- Explicit `primary_ref` controls series primacy when the native relationship set agrees. A null primary uses a stable display order without claiming the first membership is authoritative. V1/v2/v3 books retain their established behavior.
- Provider series identifiers, scopes and relationship references are retained in the validated packet; contributor credits distinguish provider identifiers from name-based identifiers. Existing series browsing still groups exact native names. Cross-library provider-ID navigation is a separate enhancement, not implemented here.
- Recording release dates, copyright-year fallbacks, work-year fallbacks and book-edition dates receive distinct labels. A legacy date without v4 provenance uses a generic Date label rather than asserting a recording release.

## Review a recording identity change

A declaration never moves listening state automatically, including one marked `verified_same_recording`. Work IDs, contributor IDs and series relationship references never become progress owners.

Choose **Pause and review saved state** to compare previous/current identities, titles, lengths, saved positions, finished state, bookmark counts and history counts. Agent conflicts and locally observed language, abridgment or length differences are shown. The app does not infer chapter alignment or retime positions.

All copy choices start off. Explicitly choose whether to replace position/completion, copy bookmarks, or copy history, then confirm the concrete selection. Positions require a known current length and must fit it; bookmarks beyond that length cannot be copied. The original source records remain under their old identity. Chosen changes use the normal Plex/iCloud synchronization settings.

The app rechecks the review inside the write transaction. A changed declaration, metadata or saved state requires another review. One copy is allowed per declared previous/current identity pair; deterministic copied row IDs also prevent duplicate bookmark/history imports. Copying does not overwrite unrelated current bookmarks or history.

Before a copy, the app atomically saves a portable snapshot of source and target listening data. On iPhone/iPad and Mac, **Export recovery backup** saves this snapshot. Normal backup import merges newer records and does not forcibly roll back newer positions. For that purpose, **Review restoring the earlier position** explicitly restores the pre-copy target position/completion after another confirmation and a check for intervening edits. Copied bookmarks/history remain retained. If the target had no pre-copy position there is no earlier position to restore. Apple TV retains the snapshot and supports position review/restoration, but has no file-export interface.

Clearing listening data explicitly also removes recording-upgrade recovery snapshots. Clearing all cached data removes metadata archives as well. A normal metadata refresh, identity change or metadata-cache clear retains identity-owned listening data.

## Storage and validation

Migration `v19_vocalismeta_v4` adds nullable cached payload/revisions and availability flags, an identity-keyed metadata archive for reviewing previous recordings, and transactional recovery snapshots. Existing metadata and listening rows are retained; legacy rows have no invented v4 payload or upgrade declaration.

The decoder checks chunk grammar/count/order consistency, base64url encoding, complete bounded zlib streams, SHA-256, exact canonical NFC/ASCII JSON and schema semantics. It binds the packet to the independently parsed v1 recording key and caps decompression at 16 KiB. It rejects duplicates, missing chunks, trailing compressed data, noncanonical numbers, invalid series references, unsafe provider identifiers and unsupported upgrade proofs. SHA-256 detects corruption; it is not a signature or proof of provider truth. Reserved v4 tags are excluded from author parsing even if validation fails.

The client reads authenticated Plex metadata only. It makes no direct provider calls and does not change agent preferences. Published v4 vectors and JSON/XML fixtures are copied unchanged into PlexKit test resources with provenance and the upstream MIT notice.

Validation: **579 package tests** (137 PlexKit, 342 Audiobooks, 57 Platform/Shared, 43 Mac platform), platform consistency checks, **69 offline release-tool tests**, and unsigned iOS/macOS/tvOS builds. Coverage includes published vectors and transport failures, same-token health changes, native overrides, explicit clears, same-URL artwork changes, non-destructive migration, reviewed copies, stale reviews, duplicate prevention and position recovery. Native AgentKit transport/field-lock behavior, signed-device playback, live Plex/iCloud delivery and native file-picker round trips still require device checks; no production accounts or user databases were used for validation.
