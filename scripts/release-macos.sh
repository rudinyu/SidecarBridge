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
  Either config may define all three generic API-key settings:
    MACOS_NOTARY_KEY_PATH, MACOS_NOTARY_KEY_ID, MACOS_NOTARY_ISSUER
  The API key file must be outside the repository and have mode 600.
  Otherwise, notarization uses SIDECARBRIDGE_NOTARY_PROFILE, then
  MACOS_NOTARY_PROFILE, then the default profile notarytool-profile.
  Signing identities remain in macOS Keychain. API-key auth uses the private
  key file above; profile auth uses a macOS Keychain profile.
  The config file is never read from Git and must have mode 600.
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
  CONFIG_MODE=$(stat -f '%Lp' "$CONFIG_PATH" 2>/dev/null || true)
  if [[ "$CONFIG_MODE" != 600 ]]; then
    echo "Release config must have mode 600." >&2
    exit 2
  fi
  # shellcheck disable=SC1090
  if ! source "$CONFIG_PATH" >/dev/null 2>&1; then
    echo "Could not load release config." >&2
    exit 2
  fi
fi

NOTARY_AUTH_MODE="keychain-profile"
NOTARY_PROFILE="${SIDECARBRIDGE_NOTARY_PROFILE:-${MACOS_NOTARY_PROFILE:-notarytool-profile}}"
NOTARY_API_KEY_PATH=""
if [[ -n "${MACOS_NOTARY_KEY_PATH+x}" || \
      -n "${MACOS_NOTARY_KEY_ID+x}" || \
      -n "${MACOS_NOTARY_ISSUER+x}" ]]; then
  if [[ -z "${MACOS_NOTARY_KEY_PATH:-}" || \
        -z "${MACOS_NOTARY_KEY_ID:-}" || \
        -z "${MACOS_NOTARY_ISSUER:-}" ]]; then
    echo "Generic notarization API-key configuration is incomplete. Set all three" \
      "MACOS_NOTARY_KEY_PATH, MACOS_NOTARY_KEY_ID, and MACOS_NOTARY_ISSUER values," \
      "or leave all three unset." >&2
    exit 2
  fi
  if [[ ! -f "$MACOS_NOTARY_KEY_PATH" ]]; then
    echo "Configured notarization API key file is missing or is not a regular file." >&2
    exit 2
  fi
  if ! NOTARY_API_KEY_PATH=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
      "$MACOS_NOTARY_KEY_PATH" 2>/dev/null); then
    echo "Could not resolve the configured notarization API key file." >&2
    exit 2
  fi
  if [[ $(stat -f '%Lp' "$NOTARY_API_KEY_PATH" 2>/dev/null || true) != 600 ]]; then
    echo "Configured notarization API key file must have mode 600." >&2
    exit 2
  fi
  if ! python3 - "$ROOT" "$NOTARY_API_KEY_PATH" >/dev/null 2>&1 <<'PY'
import os, sys

repo_root, key_path = map(os.path.realpath, sys.argv[1:])
try:
    is_inside_repository = os.path.commonpath([repo_root, key_path]) == repo_root
except ValueError:
    is_inside_repository = False
raise SystemExit(1 if is_inside_repository else 0)
PY
  then
    echo "Configured notarization API key file must resolve outside the repository." >&2
    exit 2
  fi
  NOTARY_AUTH_MODE="api-key"
fi

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
PROJECT_FILE="$ROOT/SidecarBridgeFork.xcodeproj"

build_settings_for_target() {
  local target_name="$1"
  local scheme_name="$2"
  local scheme_settings
  scheme_settings=$(xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$scheme_name" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$ROOT/.build/ReleaseMetadata" \
    -showBuildSettings \
    -json)
  python3 -c '
import json, sys
target = sys.argv[1]
settings = json.loads(sys.stdin.read())
matches = [entry["buildSettings"] for entry in settings if entry.get("target") == target]
if len(matches) != 1:
    raise SystemExit(f"Expected exactly one {target} target in xcodebuild settings, found {len(matches)}")
print(json.dumps(matches[0]))
' "$target_name" <<< "$scheme_settings"
}

read_build_setting() {
  python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$1" "$2"
}

resolve_project_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$ROOT" "$1" ;;
  esac
}

HOST_SETTINGS=$(build_settings_for_target SidecarBridgeMac SidecarBridgeMac)
VIEWER_SETTINGS=$(build_settings_for_target SidecarBridgeViewerMac SidecarBridgeViewerMac)
MARKETING_VERSION=$(read_build_setting "$HOST_SETTINGS" MARKETING_VERSION)
BUILD_NUMBER=$(read_build_setting "$HOST_SETTINGS" CURRENT_PROJECT_VERSION)
HOST_PRODUCT_NAME=$(read_build_setting "$HOST_SETTINGS" PRODUCT_NAME)
HOST_BUNDLE_ID=$(read_build_setting "$HOST_SETTINGS" PRODUCT_BUNDLE_IDENTIFIER)
HOST_ENTITLEMENTS=$(resolve_project_path "$(read_build_setting "$HOST_SETTINGS" CODE_SIGN_ENTITLEMENTS)")
VIEWER_PRODUCT_NAME=$(read_build_setting "$VIEWER_SETTINGS" PRODUCT_NAME)
VIEWER_BUNDLE_ID=$(read_build_setting "$VIEWER_SETTINGS" PRODUCT_BUNDLE_IDENTIFIER)
VIEWER_ENTITLEMENTS=$(resolve_project_path "$(read_build_setting "$VIEWER_SETTINGS" CODE_SIGN_ENTITLEMENTS)")
VIEWER_MARKETING_VERSION=$(read_build_setting "$VIEWER_SETTINGS" MARKETING_VERSION)
VIEWER_BUILD_NUMBER=$(read_build_setting "$VIEWER_SETTINGS" CURRENT_PROJECT_VERSION)
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ || -z "$MARKETING_VERSION" || \
      -z "$HOST_PRODUCT_NAME" || -z "$HOST_BUNDLE_ID" || \
      -z "$VIEWER_PRODUCT_NAME" || -z "$VIEWER_BUNDLE_ID" || \
      "$VIEWER_MARKETING_VERSION" != "$MARKETING_VERSION" || \
      "$VIEWER_BUILD_NUMBER" != "$BUILD_NUMBER" || \
      ! -f "$HOST_ENTITLEMENTS" || ! -f "$VIEWER_ENTITLEMENTS" ]]; then
  echo "Could not read matching app metadata and entitlements from the generated fork project." >&2
  exit 2
fi

HOST_APP_NAME="$HOST_PRODUCT_NAME.app"
VIEWER_APP_NAME="$VIEWER_PRODUCT_NAME.app"
HOST_ARTIFACT_STEM="${HOST_PRODUCT_NAME// /-}-$MARKETING_VERSION-$BUILD_NUMBER-macOS"
VIEWER_ARTIFACT_STEM="${VIEWER_PRODUCT_NAME// /-}-$MARKETING_VERSION-$BUILD_NUMBER-macOS"
RELEASE_ROOT="$ROOT/.build/Release$BUILD_NUMBER"

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
  echo "Notarization authentication mode: $NOTARY_AUTH_MODE"
  echo "Xcode: $DEVELOPER_DIR"
  echo "Signing identity: $SIGNING_IDENTITY"
  echo "Project version: $MARKETING_VERSION ($BUILD_NUMBER)"
  exit 0
fi

if (( CLEAN )); then
  rm -rf -- "$RELEASE_ROOT"
fi
mkdir -p "$RELEASE_ROOT"

HOST_DERIVED="$RELEASE_ROOT/HostDerivedData"
VIEWER_DERIVED="$RELEASE_ROOT/ViewerDerivedData"
TEST_DERIVED="$RELEASE_ROOT/TestDerivedData"
VIEWER_UI_TEST_DERIVED="$RELEASE_ROOT/ViewerUITestDerivedData"
HOST_APP="$HOST_DERIVED/Build/Products/Release/$HOST_APP_NAME"
VIEWER_APP="$VIEWER_DERIVED/Build/Products/Release/$VIEWER_APP_NAME"
HOST_TEST_RESULT="$RELEASE_ROOT/SidecarBridgeHostTests.xcresult"
VIEWER_UI_RESULT="$RELEASE_ROOT/SidecarBridgeViewerUITests.xcresult"
UPLOAD_DIR="$RELEASE_ROOT/notary-upload"
SIGNED_DIR="$RELEASE_ROOT/signed"
FINAL_DIR="$RELEASE_ROOT/notarized"

mkdir -p "$UPLOAD_DIR"

rm -rf -- "$HOST_TEST_RESULT" "$VIEWER_UI_RESULT"
xcodebuild -quiet \
  -project "$PROJECT_FILE" \
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
    -project "$PROJECT_FILE" \
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
  -project "$PROJECT_FILE" \
  -scheme SidecarBridgeMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$HOST_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild -quiet \
  -project "$PROJECT_FILE" \
  -scheme SidecarBridgeViewerMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$VIEWER_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

codesign --force --timestamp --options runtime --generate-entitlement-der \
  --entitlements "$HOST_ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" "$HOST_APP"
codesign --force --timestamp --options runtime --generate-entitlement-der \
  --entitlements "$VIEWER_ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" "$VIEWER_APP"

for app in "$HOST_APP" "$VIEWER_APP"; do
  codesign --verify --deep --strict --verbose=2 "$app"
done

HOST_ZIP="$UPLOAD_DIR/$HOST_ARTIFACT_STEM.zip"
VIEWER_ZIP="$UPLOAD_DIR/$VIEWER_ARTIFACT_STEM.zip"
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
validate_zip "$HOST_ZIP" "$HOST_APP_NAME" "$HOST_BUNDLE_ID" "$RELEASE_ROOT/VerifySigned/Host"
validate_zip "$VIEWER_ZIP" "$VIEWER_APP_NAME" "$VIEWER_BUNDLE_ID" "$RELEASE_ROOT/VerifySigned/Viewer"

if (( ! NOTARIZE )); then
  mkdir -p "$SIGNED_DIR"
  HOST_ARTIFACT="$SIGNED_DIR/$HOST_ARTIFACT_STEM-Signed.zip"
  VIEWER_ARTIFACT="$SIGNED_DIR/$VIEWER_ARTIFACT_STEM-Signed.zip"
  cp "$HOST_ZIP" "$HOST_ARTIFACT"
  cp "$VIEWER_ZIP" "$VIEWER_ARTIFACT"
  ARTIFACT_DIR="$SIGNED_DIR"
  ARTIFACT_STATUS="signed"
  HOST_NOTARY_ID=""
  VIEWER_NOTARY_ID=""
  HOST_NOTARY_STATUS="not-submitted"
  VIEWER_NOTARY_STATUS="not-submitted"
else
  if [[ "$NOTARY_AUTH_MODE" == "api-key" ]]; then
    notary_args=(--key "$NOTARY_API_KEY_PATH" \
      --key-id "$MACOS_NOTARY_KEY_ID" --issuer "$MACOS_NOTARY_ISSUER")
  else
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
  fi
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
  HOST_ARTIFACT="$FINAL_DIR/$HOST_ARTIFACT_STEM-Notarized.zip"
  VIEWER_ARTIFACT="$FINAL_DIR/$VIEWER_ARTIFACT_STEM-Notarized.zip"
  ditto -c -k --sequesterRsrc --keepParent "$HOST_APP" \
    "$HOST_ARTIFACT"
  ditto -c -k --sequesterRsrc --keepParent "$VIEWER_APP" \
    "$VIEWER_ARTIFACT"
  ARTIFACT_DIR="$FINAL_DIR"
  ARTIFACT_STATUS="notarized-and-stapled"
  rm -rf -- "$RELEASE_ROOT/VerifyNotarized"
  validate_zip "$HOST_ARTIFACT" "$HOST_APP_NAME" "$HOST_BUNDLE_ID" "$RELEASE_ROOT/VerifyNotarized/Host"
  validate_zip "$VIEWER_ARTIFACT" "$VIEWER_APP_NAME" "$VIEWER_BUNDLE_ID" "$RELEASE_ROOT/VerifyNotarized/Viewer"
  xcrun stapler validate -q "$RELEASE_ROOT/VerifyNotarized/Host/$HOST_APP_NAME"
  xcrun stapler validate -q "$RELEASE_ROOT/VerifyNotarized/Viewer/$VIEWER_APP_NAME"
  spctl --assess --type execute --verbose=4 "$RELEASE_ROOT/VerifyNotarized/Host/$HOST_APP_NAME"
  spctl --assess --type execute --verbose=4 "$RELEASE_ROOT/VerifyNotarized/Viewer/$VIEWER_APP_NAME"
fi

PROJECT_REVISION=$(git rev-parse HEAD)
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
