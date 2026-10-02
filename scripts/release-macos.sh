#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/release-macos.sh [options]

Builds and signs the two macOS applications only. iPadOS is never built.

Options:
  --clean       Remove only this release's project-local .build/Release<build>
  --check       Validate local Xcode, signing, and notarization configuration
  --skip-viewer-ui-tests  Skip only the Viewer UI suite when its runner cannot start
  --notarize    Submit both ZIPs, staple tickets, and run Gatekeeper checks
  -h, --help    Show this help

Authentication:
  The shared Codex config is ~/.config/codex/notarization.env.
  A SidecarBridge-specific fallback is ~/.config/sidecarbridge/release.env.
  Either config may define:
    SIDECARBRIDGE_NOTARY_PROFILE=notarytool-profile
  or the shared generic name MACOS_NOTARY_PROFILE.
  Signing and notarization credentials remain in macOS Keychain profiles.
  The config file is never read from Git and should contain only profile names.
Use --notarize only after explicitly authorizing the Apple upload.
EOF
}

CLEAN=0
CHECK_ONLY=0
NOTARIZE=0
SKIP_VIEWER_UI_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --check) CHECK_ONLY=1 ;;
    --skip-viewer-ui-tests) SKIP_VIEWER_UI_TESTS=1 ;;
    --notarize) NOTARIZE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "${SIDECARBRIDGE_RELEASE_CONFIG:-}" ]]; then
  CONFIG_PATH="$SIDECARBRIDGE_RELEASE_CONFIG"
elif [[ -f "$HOME/.config/codex/notarization.env" ]]; then
  CONFIG_PATH="$HOME/.config/codex/notarization.env"
else
  CONFIG_PATH="$HOME/.config/sidecarbridge/release.env"
fi
if [[ -f "$CONFIG_PATH" ]]; then
  if [[ $(stat -f '%Lp' "$CONFIG_PATH") != 600 ]]; then
    echo "Release config must have mode 600: $CONFIG_PATH" >&2
    exit 2
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
fi

# Keep the repository-specific names as the internal interface while allowing
# the same owner-only config to be reused by other macOS projects.
SIDECARBRIDGE_NOTARY_PROFILE="${SIDECARBRIDGE_NOTARY_PROFILE:-${MACOS_NOTARY_PROFILE:-}}"

BUILD_NUMBER=$(awk -F '"' '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)
MARKETING_VERSION=$(awk -F '"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' project.yml)
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ || -z "$MARKETING_VERSION" ]]; then
  echo "Could not read MARKETING_VERSION/CURRENT_PROJECT_VERSION from project.yml" >&2
  exit 2
fi

RELEASE_ROOT="$ROOT/.build/Release$BUILD_NUMBER"
if (( CLEAN )); then
  rm -rf -- "$RELEASE_ROOT"
fi
mkdir -p "$RELEASE_ROOT"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
fi
if [[ -z "$DEVELOPER_DIR" || ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "No usable Xcode developer directory found" >&2
  exit 2
fi
export DEVELOPER_DIR

SIGNING_IDENTITY="${SIDECARBRIDGE_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Developer ID Application:/ { print $2; exit }')
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No Developer ID Application signing identity is available" >&2
  exit 2
fi

if (( CHECK_ONLY )); then
  echo "Notarization Keychain profile: ${SIDECARBRIDGE_NOTARY_PROFILE:-notarytool-profile}"
  echo "Xcode: $DEVELOPER_DIR"
  echo "Signing identity: $SIGNING_IDENTITY"
  echo "Project version: $MARKETING_VERSION ($BUILD_NUMBER)"
  exit 0
fi

HOST_DERIVED="$RELEASE_ROOT/HostDerivedData"
VIEWER_DERIVED="$RELEASE_ROOT/ViewerDerivedData"
TEST_DERIVED="$RELEASE_ROOT/TestDerivedData"
VIEWER_UI_TEST_DERIVED="$RELEASE_ROOT/ViewerUITestDerivedData"
HOST_APP="$HOST_DERIVED/Build/Products/Release/SidecarBridge.app"
VIEWER_APP="$VIEWER_DERIVED/Build/Products/Release/SidecarBridge Viewer.app"
HOST_TEST_RESULT="$RELEASE_ROOT/SidecarBridgeHostTests.xcresult"
VIEWER_UI_RESULT="$RELEASE_ROOT/SidecarBridgeViewerUITests.xcresult"
UPLOAD_DIR="$RELEASE_ROOT/notary-upload"
SIGNED_DIR="$RELEASE_ROOT/signed"
FINAL_DIR="$RELEASE_ROOT/notarized"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
else
  echo "xcodegen is unavailable; building the checked-in SidecarBridge.xcodeproj"
fi

mkdir -p "$UPLOAD_DIR"

rm -rf -- "$HOST_TEST_RESULT" "$VIEWER_UI_RESULT"
xcodebuild -quiet \
  -project SidecarBridge.xcodeproj \
  -scheme SidecarBridgeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$TEST_DERIVED" \
  -resultBundlePath "$HOST_TEST_RESULT" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test

VIEWER_UI_STATUS="passed"
VIEWER_UI_SKIP_REASON=""
if (( ! SKIP_VIEWER_UI_TESTS )); then
  xcodebuild -quiet \
    -project SidecarBridge.xcodeproj \
    -scheme SidecarBridgeViewerUI \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$VIEWER_UI_TEST_DERIVED" \
    -resultBundlePath "$VIEWER_UI_RESULT" \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=YES \
    test
else
  VIEWER_UI_STATUS="skipped"
  VIEWER_UI_SKIP_REASON="${SIDECARBRIDGE_UI_TEST_SKIP_REASON:-not specified}"
  rm -rf -- "$VIEWER_UI_RESULT"
fi

TEST_STATUS="passed"

xcodebuild -quiet \
  -project SidecarBridge.xcodeproj \
  -scheme SidecarBridgeMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$HOST_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild -quiet \
  -project SidecarBridge.xcodeproj \
  -scheme SidecarBridgeViewerMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$VIEWER_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

codesign --force --timestamp --options runtime --generate-entitlement-der \
  --entitlements Mac/SidecarBridgeMac.entitlements \
  --sign "$SIGNING_IDENTITY" "$HOST_APP"
codesign --force --timestamp --options runtime --generate-entitlement-der \
  --entitlements MacViewer/SidecarBridgeViewer.entitlements \
  --sign "$SIGNING_IDENTITY" "$VIEWER_APP"

for app in "$HOST_APP" "$VIEWER_APP"; do
  codesign --verify --deep --strict --verbose=2 "$app"
done

HOST_ZIP="$UPLOAD_DIR/SidecarBridge-$MARKETING_VERSION-$BUILD_NUMBER-macOS.zip"
VIEWER_ZIP="$UPLOAD_DIR/SidecarBridge-Viewer-$MARKETING_VERSION-$BUILD_NUMBER-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$HOST_APP" "$HOST_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$VIEWER_APP" "$VIEWER_ZIP"

validate_zip() {
  local zip="$1"
  local app_name="$2"
  local bundle_id="$3"
  local verify_root="$4"
  local app="$verify_root/$app_name"
  unzip -tq "$zip"
  mkdir -p "$verify_root"
  ditto -x -k "$zip" "$verify_root"
  [[ -d "$app" ]] || { echo "Expected app missing from ZIP: $app" >&2; return 1; }
  local actual_version actual_build actual_bundle
  actual_version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
  actual_build=$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")
  actual_bundle=$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")
  [[ "$actual_version" == "$MARKETING_VERSION" && "$actual_build" == "$BUILD_NUMBER" && "$actual_bundle" == "$bundle_id" ]] || {
    echo "Unexpected app metadata in $zip: $actual_bundle $actual_version ($actual_build)" >&2
    return 1
  }
  codesign --verify --deep --strict --verbose=2 "$app"
  echo "Verified ZIP: $zip ($actual_bundle $actual_version/$actual_build)"
}

rm -rf -- "$RELEASE_ROOT/VerifySigned"
validate_zip "$HOST_ZIP" "SidecarBridge.app" "io.sidecarbridge.mac" "$RELEASE_ROOT/VerifySigned/Host"
validate_zip "$VIEWER_ZIP" "SidecarBridge Viewer.app" "io.sidecarbridge.viewer.mac" "$RELEASE_ROOT/VerifySigned/Viewer"

if (( ! NOTARIZE )); then
  mkdir -p "$SIGNED_DIR"
  cp "$HOST_ZIP" "$SIGNED_DIR/SidecarBridge-$MARKETING_VERSION-$BUILD_NUMBER-macOS-Signed.zip"
  cp "$VIEWER_ZIP" "$SIGNED_DIR/SidecarBridge-Viewer-$MARKETING_VERSION-$BUILD_NUMBER-macOS-Signed.zip"
  ARTIFACT_DIR="$SIGNED_DIR"
  ARTIFACT_STATUS="signed"
  HOST_NOTARY_ID=""
  VIEWER_NOTARY_ID=""
  HOST_NOTARY_STATUS="not-submitted"
  VIEWER_NOTARY_STATUS="not-submitted"
else
  notary_args=(--keychain-profile "${SIDECARBRIDGE_NOTARY_PROFILE:-notarytool-profile}")
  submit() {
    local zip="$1"
    xcrun notarytool submit "$zip" "${notary_args[@]}" \
      --wait --output-format json --no-progress
  }
  HOST_RESPONSE=$(submit "$HOST_ZIP")
  printf '%s\n' "$HOST_RESPONSE"
  HOST_NOTARY_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<< "$HOST_RESPONSE")
  HOST_NOTARY_STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<< "$HOST_RESPONSE")
  VIEWER_RESPONSE=$(submit "$VIEWER_ZIP")
  printf '%s\n' "$VIEWER_RESPONSE"
  VIEWER_NOTARY_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<< "$VIEWER_RESPONSE")
  VIEWER_NOTARY_STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<< "$VIEWER_RESPONSE")
  [[ "$HOST_NOTARY_STATUS" == "Accepted" && "$VIEWER_NOTARY_STATUS" == "Accepted" ]] || {
    echo "Apple notarization did not accept both apps." >&2
    exit 1
  }
  mkdir -p "$FINAL_DIR"
  for app in "$HOST_APP" "$VIEWER_APP"; do
    xcrun stapler staple "$app"
    xcrun stapler validate -q "$app"
    spctl --assess --type execute --verbose=4 "$app"
  done
  ditto -c -k --sequesterRsrc --keepParent "$HOST_APP" \
    "$FINAL_DIR/SidecarBridge-$MARKETING_VERSION-$BUILD_NUMBER-macOS-Notarized.zip"
  ditto -c -k --sequesterRsrc --keepParent "$VIEWER_APP" \
    "$FINAL_DIR/SidecarBridge-Viewer-$MARKETING_VERSION-$BUILD_NUMBER-macOS-Notarized.zip"
  ARTIFACT_DIR="$FINAL_DIR"
  ARTIFACT_STATUS="notarized-and-stapled"
  rm -rf -- "$RELEASE_ROOT/VerifyNotarized"
  validate_zip "$FINAL_DIR/SidecarBridge-$MARKETING_VERSION-$BUILD_NUMBER-macOS-Notarized.zip" \
    "SidecarBridge.app" "io.sidecarbridge.mac" "$RELEASE_ROOT/VerifyNotarized/Host"
  validate_zip "$FINAL_DIR/SidecarBridge-Viewer-$MARKETING_VERSION-$BUILD_NUMBER-macOS-Notarized.zip" \
    "SidecarBridge Viewer.app" "io.sidecarbridge.viewer.mac" "$RELEASE_ROOT/VerifyNotarized/Viewer"
  xcrun stapler validate -q "$RELEASE_ROOT/VerifyNotarized/Host/SidecarBridge.app"
  xcrun stapler validate -q "$RELEASE_ROOT/VerifyNotarized/Viewer/SidecarBridge Viewer.app"
  spctl --assess --type execute --verbose=4 "$RELEASE_ROOT/VerifyNotarized/Host/SidecarBridge.app"
  spctl --assess --type execute --verbose=4 "$RELEASE_ROOT/VerifyNotarized/Viewer/SidecarBridge Viewer.app"
fi

PROJECT_REVISION=$(git rev-parse HEAD)
HOST_ARTIFACT=$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name 'SidecarBridge-*.zip' -print | sort | head -n 1)
VIEWER_ARTIFACT=$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name 'SidecarBridge-Viewer-*.zip' -print | sort | head -n 1)
HOST_SHA=$(shasum -a 256 "$HOST_ARTIFACT" | awk '{print $1}')
VIEWER_SHA=$(shasum -a 256 "$VIEWER_ARTIFACT" | awk '{print $1}')
PROVENANCE="$RELEASE_ROOT/provenance.json"
python3 - "$PROVENANCE" "$MARKETING_VERSION" "$BUILD_NUMBER" "$PROJECT_REVISION" \
  "$TEST_STATUS" "$HOST_TEST_RESULT" "$VIEWER_UI_STATUS" "$VIEWER_UI_RESULT" "$VIEWER_UI_SKIP_REASON" \
  "$ARTIFACT_STATUS" "$HOST_NOTARY_ID" "$HOST_NOTARY_STATUS" \
  "$VIEWER_NOTARY_ID" "$VIEWER_NOTARY_STATUS" "$HOST_ARTIFACT" "$HOST_SHA" "$VIEWER_ARTIFACT" "$VIEWER_SHA" <<'PY'
import json
import subprocess
import sys

(path, version, build, revision, test_status, host_test_result, viewer_ui_status,
 viewer_ui_result, viewer_ui_skip_reason, artifact_status,
 host_id, host_notary_status, viewer_id, viewer_notary_status,
 host_artifact, host_sha, viewer_artifact, viewer_sha) = sys.argv[1:]
status = subprocess.run(
    ["git", "status", "--porcelain", "--untracked-files=all"],
    check=True, capture_output=True, text=True,
).stdout.splitlines()
data = {
    "version": version,
    "build": int(build),
    "gitRevision": revision,
    "workingTreeDirty": bool(status),
    "workingTreeStatus": status,
    "validation": {
        "status": "passed" if test_status == "passed" and viewer_ui_status == "passed" else "partial",
        "hostUnitTests": {
            "status": test_status,
            "resultBundle": host_test_result,
        },
        "viewerUITests": {
            "status": viewer_ui_status,
            "resultBundle": viewer_ui_result if viewer_ui_status == "passed" else None,
            "skipReason": viewer_ui_skip_reason or None,
        },
    },
    "notarization": {
        "status": artifact_status if artifact_status.startswith("notarized") else "not-submitted",
        "hostSubmissionID": host_id or None,
        "hostStatus": host_notary_status,
        "viewerSubmissionID": viewer_id or None,
        "viewerStatus": viewer_notary_status,
    },
    "artifacts": [
        {"path": host_artifact, "sha256": host_sha, "zipIntegrity": "passed", "bundleValidation": "passed"},
        {"path": viewer_artifact, "sha256": viewer_sha, "zipIntegrity": "passed", "bundleValidation": "passed"},
    ],
}
with open(path, "w", encoding="utf-8") as output:
    json.dump(data, output, indent=2, ensure_ascii=False)
    output.write("\n")
PY

echo "Release artifacts: $ARTIFACT_DIR"
echo "Provenance: $PROVENANCE"
shasum -a 256 "$HOST_ARTIFACT" "$VIEWER_ARTIFACT"
