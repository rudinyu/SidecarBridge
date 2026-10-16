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

if [[ "${SIDECARBRIDGE_BUILD_LOCK_ROOT:-}" != "$ROOT" ]]; then
  exec "$ROOT/scripts/with-build-lock.sh" "$0" "$@"
fi

source "$ROOT/scripts/lib/environment.sh"
source "$ROOT/scripts/lib/ui-test-preflight.sh"

sidecarbridge_resolve_developer_dir
sidecarbridge_resolve_xcodegen
sidecarbridge_check_xcodegen_version

"$ROOT/scripts/generate-fork-project.sh"

BUILD_ROOT="$ROOT/.build/CI"
HOST_TEST_RESULT="$BUILD_ROOT/SidecarBridgeHostTests.xcresult"
VIEWER_UI_RESULT="$BUILD_ROOT/SidecarBridgeViewerUITests.xcresult"
mkdir -p "$BUILD_ROOT"
ENVIRONMENT_REPORT="$BUILD_ROOT/environment.log"
if ! "$ROOT/scripts/check-environment.sh" >"$ENVIRONMENT_REPORT" 2>&1; then
  cat "$ENVIRONMENT_REPORT" >&2
  exit 1
fi
cat "$ENVIRONMENT_REPORT"

python3 "$ROOT/Tests/test_environment_scripts.py"
python3 "$ROOT/Tests/test_release_macos_adapter.py"

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

UI_TEST_STATUS="skipped"
UI_TEST_SKIP_REASON=""
if (( SKIP_VIEWER_UI_TESTS )); then
  UI_TEST_SKIP_REASON="explicitly requested with --skip-viewer-ui-tests"
  echo "Viewer UI tests skipped: $UI_TEST_SKIP_REASON."
elif sidecarbridge_ui_test_preflight; then
  UI_TEST_STATUS="ready"
else
  UI_TEST_SKIP_REASON="$UI_TEST_PREFLIGHT_REASON"
fi

if [[ "$UI_TEST_STATUS" == "ready" ]]; then
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
  UI_TEST_STATUS="passed"
else
  rm -rf -- "$VIEWER_UI_RESULT"
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

if [[ "$UI_TEST_STATUS" == "skipped" ]]; then
  echo "Non-UI Host tests and both Release builds passed; Viewer UI tests skipped ($UI_TEST_SKIP_REASON); full CI gate is incomplete."
  if (( ! SKIP_VIEWER_UI_TESTS )); then
    exit 3
  fi
else
  echo "macOS Host unit tests and Viewer UI tests passed; both Release apps built."
fi
