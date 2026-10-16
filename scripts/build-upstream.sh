#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

if (( $# > 0 )); then
  case "$1" in
    -h|--help)
      echo "Usage: scripts/build-upstream.sh"
      echo "Builds and tests the author-owned macOS and iOS/iPadOS targets."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
fi

if [[ "${SIDECARBRIDGE_BUILD_LOCK_ROOT:-}" != "$ROOT" ]]; then
  exec "$ROOT/scripts/with-build-lock.sh" "$0" "$@"
fi

source "$ROOT/scripts/lib/environment.sh"
sidecarbridge_resolve_developer_dir
sidecarbridge_resolve_xcodegen
sidecarbridge_check_xcodegen_version

BUILD_ROOT="$ROOT/.build/Upstream"
"$XCODEGEN" generate --spec "$ROOT/project.yml"

xcodebuild \
  -project "$ROOT/SidecarBridge.xcodeproj" \
  -scheme SidecarBridgeMac \
  -configuration Debug \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project "$ROOT/SidecarBridge.xcodeproj" \
  -scheme SidecarBridgePad \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_ROOT/DerivedDataPad" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project "$ROOT/SidecarBridge.xcodeproj" \
  -scheme SidecarBridgeMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  test

echo "Author-owned macOS and iOS/iPadOS build products are under $BUILD_ROOT."
