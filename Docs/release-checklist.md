# Release checklist

This checklist distinguishes verified source changes from account and asset work required before a public release.

- [ ] Run GitHub CI on the actual repository and confirm all checks pass.
- [ ] Build and sign release archives with the intended team and effective bundle identifiers.
- [ ] Confirm iCloud/push capabilities and deploy the schema to Production; verify a TestFlight build with two devices.
- [ ] Complete the device scenarios in [CloudKit setup](cloudkit.md) and [data recovery](data-recovery.md), including suspended/system-terminated background downloads.
- [ ] Retake iPhone and iPad screenshots from the current UI with a lawful demo library: Home, Books, People, player and downloads. Existing captures predate the People tab and Books header. Do not submit them as current screenshots.
- [ ] Replace matching images in both `Docs/app-store/` and `public-web/screenshots/`; check image dimensions, no alpha and 8-bit channels using the requirements in [submitting](submitting.md).
- [ ] Verify narrator/author credits and cover/audio rights for every screenshot and review-library item.
- [ ] Add the real published store URLs to `STORES` in `public-web/index.php` after listings exist. Null URLs intentionally display “Coming to the” store labels; guessed URLs must not be substituted.
- [ ] Verify privacy/support URLs and review credentials; do not commit credentials to the repository.
- [ ] Retain GPL and dependency notices with source distributions.

The source fixes cannot supply current authenticated demo-library captures, actual App Store listing URLs, signing access or CloudKit production deployment. Those remain release tasks until the corresponding assets/accounts exist. See [audit fixes](audit-fixes.md) for local verification results.

Repository source releases use [the GitLab/GitHub release guide](RELEASING.md). Run `make release-tests` and `make website-check`; build, check and prepare before the explicit publication command. Review tag, destinations, notes and upload hashes in the manifest. Repository releases and App Store uploads are separate steps.
