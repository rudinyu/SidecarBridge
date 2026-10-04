#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

usage() {
  echo "Usage: scripts/ci-macos.sh [--skip-viewer-ui-tests]"
}

SKIP_VIEWER_UI_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --skip-viewer-ui-tests) SKIP_VIEWER_UI_TESTS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
fi
if [[ -z "$DEVELOPER_DIR" || ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "No usable Xcode developer directory found" >&2
  exit 2
fi
export DEVELOPER_DIR

"$ROOT/scripts/generate-fork-project.sh"

BUILD_ROOT="$ROOT/.build/CI"
HOST_TEST_RESULT="$BUILD_ROOT/SidecarBridgeHostTests.xcresult"
VIEWER_UI_RESULT="$BUILD_ROOT/SidecarBridgeViewerUITests.xcresult"
mkdir -p "$BUILD_ROOT"
rm -rf -- "$HOST_TEST_RESULT" "$VIEWER_UI_RESULT"

if ! xcodebuild -quiet \
  -project SidecarBridgeFork.xcodeproj \
  -scheme SidecarBridgeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_ROOT/TestDerivedData" \
  -resultBundlePath "$HOST_TEST_RESULT" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test; then
  echo "Host XCTest failed; result summary follows:" >&2
  xcrun xcresulttool get test-results summary --path "$HOST_TEST_RESULT" || true
  exit 1
fi

if (( ! SKIP_VIEWER_UI_TESTS )); then
  if ! xcodebuild -quiet \
    -project SidecarBridgeFork.xcodeproj \
    -scheme SidecarBridgeViewerUI \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_ROOT/ViewerUITestDerivedData" \
    -resultBundlePath "$VIEWER_UI_RESULT" \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=YES \
    test; then
    echo "Viewer UI XCTest failed; result summary follows:" >&2
    xcrun xcresulttool get test-results summary --path "$VIEWER_UI_RESULT" || true
    exit 1
  fi
else
  echo "Viewer UI tests skipped by explicit request."
fi

xcodebuild -quiet \
  -project SidecarBridgeFork.xcodeproj \
  -scheme SidecarBridgeMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_ROOT/HostReleaseDerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild -quiet \
  -project SidecarBridgeFork.xcodeproj \
  -scheme SidecarBridgeViewerMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_ROOT/ViewerReleaseDerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

if (( SKIP_VIEWER_UI_TESTS )); then
  echo "Host unit tests passed; Viewer UI tests were skipped; both Release apps built."
else
  echo "macOS Host unit tests and Viewer UI tests passed; both Release apps built."
fi
