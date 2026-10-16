#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

usage() {
  echo "Usage: scripts/build.sh [--clean]"
  echo "Builds the fork's macOS Host and Viewer without building iOS/iPadOS."
}

CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "${SIDECARBRIDGE_BUILD_LOCK_ROOT:-}" != "$ROOT" ]]; then
  exec "$ROOT/scripts/with-build-lock.sh" "$0" "$@"
fi

source "$ROOT/scripts/lib/environment.sh"
sidecarbridge_resolve_developer_dir
sidecarbridge_resolve_xcodegen
sidecarbridge_check_xcodegen_version

BUILD_ROOT="$ROOT/.build/Development"
if (( CLEAN )); then
  rm -rf -- "$BUILD_ROOT"
fi

"$ROOT/scripts/generate-fork-project.sh"

HOST_DERIVED="$BUILD_ROOT/HostDerivedData"
VIEWER_DERIVED="$BUILD_ROOT/ViewerDerivedData"
mkdir -p "$BUILD_ROOT"

xcodebuild \
  -project "$ROOT/SidecarBridgeFork.xcodeproj" \
  -scheme SidecarBridgeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOST_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project "$ROOT/SidecarBridgeFork.xcodeproj" \
  -scheme SidecarBridgeViewerMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$VIEWER_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "Host app: $HOST_DERIVED/Build/Products/Debug/ScreenDock Host.app"
echo "Viewer app: $VIEWER_DERIVED/Build/Products/Debug/ScreenDock Viewer.app"
echo "The upstream iPhone/iPad build remains available through scripts/build-upstream.sh."
