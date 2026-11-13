# GitLab and GitHub release tooling

Adapted from the ZIFburn archive's Python release workflow and its BitSkim helpers. Upstream MIT notices remain in `scripts/`. Python 3.9+, Git, full Xcode, XcodeGen and PHP are needed for a complete build; offline release-tool tests need only Python and Git. Use the same checkout throughout build/preparation/publication.

## Project settings

The default external settings file is:

```text
~/Development/tools/git-release/projects/vocalisbook.json
```

It is configured separately from the public checkout. `examples/release-config.json` documents the format without disclosing the internal host. Override with `--config /path/to/settings.json` or `VOCALISBOOK_RELEASE_CONFIG`. No tokens belong in this file. Repository URLs must be credential-free HTTPS; `github_git`/`gitlab_git` may select matching ordinary SSH destinations. Nested GitLab groups are supported. The default port is 443. Internal certificate authorities must be trusted by Python; do not disable TLS verification.

`source_branch` selects the destination branch (the configured installation uses `main`). An empty string preserves the current local branch. `env` permits only `PHP` (executable name/path) and `VOCALISBOOK_RELEASE_PYTHON` (persistent Python executable). Developer ID and notarization profiles from ZIFburn are deliberately not part of this source/website release configuration.

## Credentials

The installed settings reference `GITHUB_TOKEN` and `GITLAB_TOKEN`. Supply them through your normal secure environment/CI secret mechanism. The tool does not write token values to the checkout, arguments or settings. Git source/tag pushes use your SSH agent or Git credential helper independently of API credentials.

For 1Password, replace a service's credential reference with either:

```json
{"provider": "1password", "reference": "op://Vault/Item/Field"}
```

or:

```json
{"provider": "1password", "vault": "Vault", "item": "Repository token", "field": "group/repository-rw", "account": ""}
```

An optional `account` selects the account. The named-field form handles labels containing slashes. The `op` CLI must already be authenticated. Missing, ambiguous or cancelled lookups stop without printing secret output. The integration does not create 1Password fields or tokens.

GitHub credentials need repository Contents write access; GitLab credentials need API/package/release access and suitable project permissions. Protected branches/tags may require additional rights. The tool preflights repository identity/access and existing releases before remote writes, but each server remains authoritative. API credentials are loaded only for publication; build subprocesses have configured API-token environment variables removed. Checks for known token bytes are not a complete history/secret audit.

## Initialize or preserve Git history

An extracted source folder can build, check and prepare without Git history. Publishing requires a clean committed checkout and tracked release inputs.

If the remotes are empty and this folder has no history:

```sh
python3 -B scripts/release.py source --init --to gitlab,github --dry-run
```

`--init` checks both remotes are empty and reachable, checks Git author identity, initializes the local branch, and commits only the reviewed source allowlist. It changes local Git metadata even with `--dry-run` but uploads nothing. It is never performed by build or prepare. If either remote has history, clone/preserve that history instead of initializing over it. No initialization or remote upload was performed as part of this integration.

For an existing checkout, review and commit your changes before building. Build outputs, generated Xcode projects, SwiftPM caches, build counters, `outputs/` and local `work/` settings are excluded from source archives and ignored. Unexpected untracked files still block publication until reviewed; ignored release inputs also block it. Never commit local databases, provisioning material or tokens.

## Source upload without a release

```sh
python3 -B scripts/release.py source --to gitlab,github --dry-run
python3 -B scripts/release.py source --to gitlab,github --confirm-push
```

Every destination is dry-run first. The current branch is pushed to `source_branch`; this does not push all tags, create releases or publish assets. Force and mirror pushes are not used. Two hosts are not a single transaction: if the second fails, inspect the error and rerun after resolving it; matching source pushes are idempotent.

## Build and verify

Set `VERSION` for the repository release and edit `Docs/RELEASE-NOTES.md`. Per-platform app versions remain independent and are recorded in provenance. Commit first if the build will be published.

```sh
make release-plan
make release-build
make release-check
```

Build runs the offline tool tests, both PHP routes/local-asset checks, `make check` and all three unsigned app builds. It then creates `outputs/artifacts/` with:

- `vocalisbook-<version>-source.tar.gz`: allowlisted source plus provenance.
- `vocalisbook-<version>-website.tar.gz`: PHP site, screenshots, logo and license notices.
- `BUILD-PROVENANCE.json`: exact source fingerprint/commit, platform versions, compiler and commands run.
- `SHA256SUMS`: exact inventory checksums.

The fingerprint excludes generated files and includes executable modes. Changing source, app-version settings or the build commit invalidates the artifacts. `release-check` compares archive members against current files, not just a newly written checksum list. It does not rebuild or contact either repository. Existing artifacts/evidence are not silently overwritten: move the previous `outputs/` aside intentionally before building another release.

`make release` is an alias for build. `make dist` makes a standalone source archive under `outputs/source/`. `make website-package` validates the site and writes `build/vocalisbook-website.tar.gz`. These standalone packages do not create publication manifests or claim a release build passed.

## Prepare, review and publish

```sh
python3 -B scripts/release.py prepare --tag v1.0.0 --tag-message "VocalisBook 1.0.0"
# Review outputs/release/manifest.json and outputs/release/publish/.
python3 -B scripts/release.py publish --to gitlab,github --confirm-publish
```

Omitting `--tag` uses `v<VERSION>`. Custom tag names and annotations are frozen in the manifest; they do not change app versions. Use `--notes /path/to/notes.md` for alternative notes. Existing release tags are not force-moved. This workflow publishes stable releases; choose the final stable tag/notes deliberately rather than treating an rc tag as automatic prerelease metadata.

Prepare freezes destinations, tag/annotation, notes, source commit/fingerprint and exact upload hashes. It creates no Git tag or remote release. Publication stages both archives and their individual SHA-256 files, provenance and `SHA256SUMS`. Only those staged bytes are uploaded.

Publish revalidates the clean source and all artifacts, preflights every selected host, creates an annotated local tag, pushes only that tag, and verifies its remote commit. GitHub assets are uploaded to a draft and the draft becomes public only after the complete inventory/digests match. GitLab assets go through the Generic Package Registry, are downloaded/hash-verified, and are linked from the release. Package versions are derived from the release tag, so custom tags sharing a repository VERSION do not collide; tags unsuitable for a package version use a deterministic hash.

A per-destination receipt in `outputs/release/receipt.json` records completed work. On interruption, preserve the manifest, staged files, artifacts and receipt, resolve the error, then rerun the same publish command. Matching work is verified and resumed; conflicting bytes, notes, destinations or tags stop without overwrite. There is no automatic network retry or cross-host rollback.

To prepare and publish an already-built release in one explicitly confirmed command:

```sh
python3 -B scripts/release.py release --to gitlab,github --confirm-publish
```

Select only `--to github` or `--to gitlab` when appropriate. Make wrappers accept the same flags through `RELEASE_ARGS`, for example `make release-source RELEASE_ARGS='--dry-run'`. Publishing still requires the explicit confirmation flag.

## CI and separate App Store distribution

GitHub CI runs offline release tests alongside the existing package tests/builds. `.gitlab-ci.yml` runs offline release tests on a Docker-capable Python runner; it does not assume an internal macOS runner. Neither pipeline automatically publishes tags/releases or receives production publishing credentials.

Keep using `make ios-archive`, `make macos-archive` and `make tvos-archive` for signed App Store archives, following [submitting](submitting.md) and the [release checklist](release-checklist.md). The repository tool does not upload simulator apps, sign/notarize a direct-download Mac app, submit to App Store Connect, update store URLs or deploy the PHP package.

API references: [GitHub releases/assets](https://docs.github.com/en/rest/releases/assets?apiVersion=2022-11-28), [GitLab releases](https://docs.gitlab.com/api/releases/), [GitLab generic packages](https://docs.gitlab.com/user/packages/generic_packages/).
