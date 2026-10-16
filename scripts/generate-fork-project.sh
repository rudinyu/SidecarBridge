#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

if (( $# > 0 )); then
  case "$1" in
    -h|--help)
      echo "Usage: scripts/generate-fork-project.sh"
      echo "Regenerates SidecarBridgeFork.xcodeproj from project.fork.yml."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
fi

if [[ "${SIDECARBRIDGE_BUILD_LOCK_ROOT:-}" != "$ROOT" ]]; then
  exec "$ROOT/scripts/with-build-lock.sh" "$0" "$@"
fi

source "$ROOT/scripts/lib/environment.sh"

PROJECT_PATH="$ROOT/SidecarBridgeFork.xcodeproj"
SPEC_PATH="$ROOT/project.fork.yml"

sidecarbridge_resolve_xcodegen
sidecarbridge_check_xcodegen_version

[[ -f "$SPEC_PATH" ]] || { echo "Fork project spec is missing: $SPEC_PATH" >&2; exit 2; }

# Never let a failed generation be mistaken for a usable previous project.
rm -rf -- "$PROJECT_PATH"
"$XCODEGEN" generate --spec "$SPEC_PATH"
[[ -f "$PROJECT_PATH/project.pbxproj" ]] || {
  echo "XcodeGen did not create the expected project: $PROJECT_PATH" >&2
  exit 1
}

echo "Generated $PROJECT_PATH from project.fork.yml with $XCODEGEN (XcodeGen $XCODEGEN_VERSION)"
