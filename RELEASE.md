# Releasing VocalisBook

Follow [Docs/RELEASING.md](Docs/RELEASING.md) for source pushes, annotated tags and repository releases to GitLab/GitHub. The release tool packages GPL-licensed source and the PHP website; it does not upload simulator binaries, sign/notarize a direct-download Mac app, deploy the website or submit to App Store Connect.

`VERSION` identifies a source-tree release. Each app's `Config/<platform>.xcconfig` keeps its own `MARKETING_VERSION`; the provenance record captures all three without forcing them to be equal. Set the repository version deliberately and finalize [release notes](Docs/RELEASE-NOTES.md) before committing and building.

Before publishing, run the [release checklist](Docs/release-checklist.md), including real device/Plex/iCloud checks. Existing `make ios-archive`, `make macos-archive` and `make tvos-archive` create signed App Store archives separately; see [submitting](Docs/submitting.md). A successful source release does not establish App Store approval or device runtime validation.

The workflow is build → check → prepare → review the manifest → explicitly publish. `make release` is build-only. Source pushes and release publication have separate confirmation flags; neither runs automatically in CI. Never force-move an existing release tag.
