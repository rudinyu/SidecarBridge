# Upstream tracking and integration

The repository's `origin` is the writable fork. The author repository is tracked
as a fetch-only `upstream` remote. Use `git fetch upstream` to inspect new author
history; do not push to `upstream` or use GitHub's automatic **Sync fork** action.

Integrate an upstream change on a separate branch created from the fork's own
current `main` branch. Review the commits and their file-level changes first,
then cherry-pick or manually adapt only the changes the fork intends to carry.
Keep that integration branch separate until it has been validated and is ready
to merge into the fork's `main`. This preserves fork-only work and makes every
upstream change an explicit integration decision.

The author-owned `project.yml` and `SidecarBridge.xcodeproj` remain at their
upstream baseline. Fork builds use `project.fork.yml`, which includes the
author's spec and adds the fork's macOS Host and standalone Viewer configuration.
Run `scripts/generate-fork-project.sh` to generate the ignored
`SidecarBridgeFork.xcodeproj`; CI and release scripts require this generation
step and never use a checked-in project as a fallback.

## ScreenDock product identity and compatibility

The fork's macOS products are **ScreenDock Host** and **ScreenDock Viewer**,
version `1.5` build `123`, with production bundle identifiers
`com.screendock.host` and `com.screendock.viewer`. Debug builds add `.debug` to
those bundle identifiers. The author-owned project remains version `1.4` build
`106`; the generated fork project keeps its iPad target at version `1.4` build
`6`, with its original bundle identity and compile settings.

ScreenDock Host preserves compatibility with the author's iPhone and iPad apps.
It advertises both original Bonjour services (`_sb-screen._tcp` and
`_sb-direct._tcp`) and ScreenDock services (`_sd-screen._tcp` and
`_sd-direct._tcp`). ScreenDock Viewer browses only for the ScreenDock services.
The existing `sidecarbridge://pair` iPad QR contract remains unchanged.

ScreenDock Host uses TCP port `45454` by default, matching the author app. It
chooses port `45455` only when the author Host is already running or port
`45454` is occupied. ScreenDock Host and Viewer use a separate trust namespace;
pair a ScreenDock Viewer with each Mac once. This first pairing does not replace
the author's saved SidecarBridge trust.

Before starting the local Viewer UI suite, run the `macos-ui-test-preflight`
check and proceed only if the desktop is ready. If it is not ready, CI may be
run with `./.codex/ci.sh --skip-viewer-ui-tests`; release checks accept the same
`--skip-viewer-ui-tests` option. Skipping the suite is not a UI-test pass.
