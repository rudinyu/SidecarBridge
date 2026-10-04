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
author's spec and adds the fork's standalone macOS Viewer targets. Run
`scripts/generate-fork-project.sh` to generate the ignored
`SidecarBridgeFork.xcodeproj`; CI and release scripts require this generation
step and never use a checked-in project as a fallback.
