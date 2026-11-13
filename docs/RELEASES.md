# Automatic application downloads

## Where to download

- [Latest Android ARM64 APK](https://github.com/agent-axiom/axiom-edge/releases/latest/download/axiom-edge-android-arm64.apk)
- [Latest iOS unsigned developer archive](https://github.com/agent-axiom/axiom-edge/releases/latest/download/axiom-edge-ios-unsigned.zip)
- [All files, release notes and checksums](https://github.com/agent-axiom/axiom-edge/releases/latest)

Every release also contains immutable per-release links in its description.
Downloads are normal GitHub Release assets, not expiring Actions artifacts.

| Platform | Published file | Installation status |
| --- | --- | --- |
| Android ARM64, API 28+ | `axiom-edge-android-arm64.apk` | Installable test APK, debug signed |
| iOS 16.4+ | `axiom-edge-ios-unsigned.zip` | Developer archive; Apple signing required before installation |
| Windows, macOS, Linux | No application package | Not currently supported by the platform bootstrap |

An unsigned iOS `.app` archive is deliberately not called an installable IPA.
Creating a distributable iOS app requires a configured Apple signing and
distribution flow. This workflow does not create or invent Apple credentials.

Android currently uses Flutter's default debug signing configuration. Fresh
runners can generate different keys: an APK may not update an older installation
in place. Uninstalling the old app removes its data. Production signing requires
a properly configured signing key; no private key is committed by this feature.

## When a release appears

Mobile CI validates Android, iOS and the reusable Rust core in parallel. All
three must succeed before the publication job can run. PRs run the checks but
never publish. A successful push to `main`, a manual main-branch run, or an
explicit version tag can publish.

For main runs the tag includes the checked-in base app version and workflow
run number, such as `v0.1.2-build.12`. This creates a new immutable release even
when a change does not bump the app's version. Repeating the same workflow run
uses the same tag and leaves an already published release unchanged. Explicit
version tags must match the version in `pubspec.yaml`.

Generated build tags are excluded from Mobile CI's tag filter. Publication uses
the built-in job token, which also avoids recursive workflow runs.

## Provenance and publication

The publication job checks out the exact tested `github.sha` and downloads the
two named artifacts from its own workflow run. It never chooses a file by
looking for the most recent run on a branch.

`tool/release.py prepare` verifies both files exist, generates SHA-256 checksums,
records the source commit, full app version, workflow run and artifact metadata
in `release.json`, and writes Russian release notes with direct download links.

`tool/release.py publish` checks the source tag, creates or resumes a draft,
uploads and verifies all assets, then publishes the complete release as latest.
A mismatched existing tag fails rather than moving that tag. A stale main run
cannot replace the current main release. Failed checks, missing files and upload
failures leave publication unsuccessful rather than showing broken download links.

Only the publication job receives `contents: write`; build and PR jobs use read
permissions. The checkout does not persist Git credentials. `GH_TOKEN` comes
from the current job's `GITHUB_TOKEN`, not a personal access token.

## Checks

Run `python3 -m unittest discover -s tool/tests -v` for bootstrap and release
regressions. Release tests use scripted CLI responses and never create real tags
or releases. Mobile CI supplies the actual builds and exercises publication on
the successful main run after merge.
