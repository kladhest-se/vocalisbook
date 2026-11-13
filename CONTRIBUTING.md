# Contributing

Start with [building and tests](Docs/building.md), [CloudKit setup](Docs/cloudkit.md) and [data recovery](Docs/data-recovery.md). Use your own signing team/container when testing iCloud. Do not commit generated Xcode projects, developer credentials, tokens, local databases or downloaded audio.

Run `make check` for package tests, platform compilation and drift checks, then build the affected apps. CI also builds all three apps unsigned. Use simulator/device tests for background lifecycle, playback, focus, accessibility and cloud integration changes. State which checks ran and which device-only behavior remains unverified.

Schema changes are append-only migrations in `Schema.swift`; update `currentVersion` and add migration/data-retention tests. Sync field names, record types and identity formats are public wire contracts. Cover changes at the CloudKit mapping/acknowledgement boundary as well as in the local store.

Keep intentionally copied platform files in agreement using `make drift`. Include a regression test for behavior that could lose listening state or falsely report a completed download. Update user documentation when data retention or recovery behavior changes.

Contributions to original project code are under GPL-3.0-or-later, matching the project license. Keep third-party copyright and license notices intact. Do not contribute audiobook audio, covers, screenshots or other material without the rights needed to distribute it.

Release-tool changes must pass `make release-tests` (offline) and `make website-check`. See [the release guide](Docs/RELEASING.md); keep project settings and credentials outside the checkout, and do not invoke publishing as part of ordinary tests or builds.
