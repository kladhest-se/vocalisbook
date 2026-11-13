# Building and testing

Use an Apple Silicon Mac with full Xcode, its command-line tools, Python 3 and XcodeGen (`brew install xcodegen`). Swift tools 6.0 or newer are required by the package manifests; Xcode 16 is the minimum toolchain family. The audit fixes were compiled with Xcode 27.2 (27B52) and XcodeGen 2.46.0. Older toolchains have not been verified for these fixes.

Select the full Xcode installation with `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer` if `xcodebuild -version` does not show it. Complete Xcode's first-launch setup and license acceptance in Xcode. Internet access is needed on the first build to resolve GRDB from GitHub. Core and platform packages commit their resolved dependency versions.

From the repository root:

```sh
make drift     # check intentionally identical platform implementations
make core      # PlexKit, Audiobooks and Platform/Shared builds and tests
make check     # drift + core + all platform packages; no app launch
make build     # packages plus all three app builds
make test      # packages and app tests; iOS/tvOS simulators required
```

`make core` needs no simulator or Plex/iCloud account. `make check` and `make build` need the iOS and tvOS platform SDKs. Install the iOS/tvOS platforms through Xcode Settings → Components if they are missing. Running `make test`, `make ios-run` or `make tvos-run` also needs matching simulator runtimes. Inspect installed runtimes with `xcrun simctl list runtimes` and available destinations with `make ios-destinations` / `make tvos-destinations`. `SIM=…` can select a specific iPhone simulator for the iOS targets.

Each app uses its own `Apps/<platform>/project.yml`. Generate it with `make ios-project`, `make macos-project` or `make tvos-project`. Generated projects and build numbers are local files and must not be committed.

An unsigned build does not require a signing team:

```sh
make ios-project
xcodebuild build -project Apps/iOS/VocalisBook.xcodeproj -scheme VocalisBook \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Use `generic/platform=tvOS Simulator` for Apple TV and `platform=macOS` for the Mac. Unsigned builds verify compilation; they do not establish that CloudKit or push entitlements work. For real devices, use `make devices`, `make teams`, then the install/archive targets documented in README. [CloudKit development setup](cloudkit.md) is required for sync under your own team.

## Checks supplied in this repository

`.github/workflows/ci.yml` runs package tests, the platform drift check and unsigned builds for every app on a macOS runner. It records the toolchain used by the runner. CI is added here but must run on your GitHub repository before a passing remote status can be claimed.

`scripts/check-drift.py` lists the files deliberately shared by copying between platforms. If one changes, update the other copies in the same group or deliberately revise the group when the implementations must diverge. Platform-specific files outside those groups are not required to match. Earlier comments referring to a separate `vocalisbook-tools` repository are superseded by these included checks.

For failures, retain the first compiler error and the failing command. A network dependency failure is different from a test failure. A simulator service failure does not establish a source-code defect. Do not erase a durable user database to work around a build or runtime error.
