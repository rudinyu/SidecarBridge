#!/usr/bin/env bash
set +x
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/release-macos.sh [options]

Builds and signs the two macOS applications only. iPadOS is never built.

Options:
  --clean       Remove only this release's .build/ReleaseBuildCache<build>
  --check       Validate local Xcode, signing, and notarization configuration
  --skip-viewer-ui-tests  Explicitly skip the Viewer UI suite; release validation is partial
  --notarize    Submit both ZIPs, staple tickets, and run Gatekeeper checks
  -h, --help    Show this help

Authentication:
  The shared Codex config is ~/.config/codex/notarization.env.
  An explicit SIDECARBRIDGE_RELEASE_CONFIG is parsed literally as a
  SidecarBridge override. Otherwise ~/.config/sidecarbridge/release.env is
  used only when the shared config is absent. Config files must be owner-only.
  Either config may define all three generic API-key settings:
    MACOS_NOTARY_KEY_PATH, MACOS_NOTARY_KEY_ID, MACOS_NOTARY_ISSUER
  The API key file must be owner-only and outside this repository.
  A configured Keychain profile takes precedence over API-key settings.
  Otherwise a complete API-key tuple is selected; if no auth is configured,
  notarytool-profile is the final profile fallback. The shared helper parses
  literal settings and never sources a config as shell code.
  Within a config/environment source, SIDECARBRIDGE_NOTARY_PROFILE overrides
  MACOS_NOTARY_PROFILE; SIDECARBRIDGE_SIGNING_IDENTITY overrides
  MACOS_SIGNING_IDENTITY. The selected certificate label is public, while
  private signing material stays in Keychain.
Use --notarize only when the current release task authorizes Apple uploads.
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
    *) echo "Unknown option." >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "${SIDECARBRIDGE_BUILD_LOCK_ROOT:-}" != "$ROOT" ]]; then
  exec "$ROOT/scripts/with-build-lock.sh" "$0" "$@"
fi

source "$ROOT/scripts/lib/environment.sh"
source "$ROOT/scripts/lib/ui-test-preflight.sh"

NOTARIZATION_HELPER="$HOME/.codex/skills/macos-notarization-release/scripts/macos_notarization.py"
if [[ ! -f "$NOTARIZATION_HELPER" ]]; then
  echo "Shared macOS notarization helper is unavailable." >&2
  exit 2
fi

# Preserve the adapter's legacy config selection while keeping parsing in the
# shared helper. An explicit project config overrides shared settings; the
# default project config remains a fallback only when shared config is absent.
PROJECT_CONFIG_PATH=""
if [[ -n "${SIDECARBRIDGE_RELEASE_CONFIG:-}" ]]; then
  PROJECT_CONFIG_PATH="$SIDECARBRIDGE_RELEASE_CONFIG"
elif [[ ! -e "$HOME/.config/codex/notarization.env" && \
        -f "$HOME/.config/sidecarbridge/release.env" ]]; then
  PROJECT_CONFIG_PATH="$HOME/.config/sidecarbridge/release.env"
fi

AUTH_ARGS=(resolve-auth --default-profile notarytool-profile --project-root "$ROOT")
if [[ -n "${SIDECARBRIDGE_NOTARY_PROFILE:-}" ]]; then
  AUTH_ARGS+=(--profile "$SIDECARBRIDGE_NOTARY_PROFILE")
fi
if [[ -n "$PROJECT_CONFIG_PATH" ]]; then
  AUTH_ARGS+=(--project-config "$PROJECT_CONFIG_PATH")
fi
NOTARY_AUTH_MODE=$(python3 "$NOTARIZATION_HELPER" "${AUTH_ARGS[@]}")

DEVELOPER_DIR="${DEVELOPER_DIR:-}"
sidecarbridge_resolve_developer_dir

run_release_tool() {
  /usr/bin/env \
    -u MACOS_NOTARY_PROFILE \
    -u MACOS_NOTARY_KEY_PATH \
    -u MACOS_NOTARY_KEY_ID \
    -u MACOS_NOTARY_ISSUER \
    -u SIDECARBRIDGE_NOTARY_PROFILE \
    -u SIDECARBRIDGE_RELEASE_CONFIG \
    "$@"
}

run_release_tool "$ROOT/scripts/generate-fork-project.sh"
PROJECT_FILE="$ROOT/SidecarBridgeFork.xcodeproj"

build_settings_for_target() {
  local target_name="$1"
  local scheme_name="$2"
  local scheme_settings
  scheme_settings=$(run_release_tool xcodebuild \
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
RELEASE_CACHE_ROOT="$ROOT/.build/ReleaseBuildCache$BUILD_NUMBER"
RELEASE_ARTIFACT_ROOT="$ROOT/dist/releases/Release$BUILD_NUMBER"

DEFAULT_SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null |
  awk -F '"' '/Developer ID Application:/ { print $2; exit }' || true)
IDENTITY_ARGS=(resolve-signing-identity)
if [[ -n "$DEFAULT_SIGNING_IDENTITY" ]]; then
  IDENTITY_ARGS+=(--default-identity "$DEFAULT_SIGNING_IDENTITY")
fi
if [[ -n "${SIDECARBRIDGE_SIGNING_IDENTITY:-}" ]]; then
  IDENTITY_ARGS+=(--identity "$SIDECARBRIDGE_SIGNING_IDENTITY")
fi
if [[ -n "$PROJECT_CONFIG_PATH" ]]; then
  IDENTITY_ARGS+=(--project-config "$PROJECT_CONFIG_PATH")
fi
SIGNING_IDENTITY=$(python3 "$NOTARIZATION_HELPER" "${IDENTITY_ARGS[@]}")

if (( CHECK_ONLY )); then
  echo "Notarization authentication mode: $NOTARY_AUTH_MODE"
  echo "Xcode: $DEVELOPER_DIR"
  echo "Signing identity: $SIGNING_IDENTITY"
  echo "Project version: $MARKETING_VERSION ($BUILD_NUMBER)"
  exit 0
fi

if (( CLEAN )); then
  rm -rf -- "$RELEASE_CACHE_ROOT"
fi
mkdir -p "$RELEASE_CACHE_ROOT" "$RELEASE_ARTIFACT_ROOT"

HOST_DERIVED="$RELEASE_CACHE_ROOT/HostDerivedData"
VIEWER_DERIVED="$RELEASE_CACHE_ROOT/ViewerDerivedData"
TEST_DERIVED="$RELEASE_CACHE_ROOT/TestDerivedData"
VIEWER_UI_TEST_DERIVED="$RELEASE_CACHE_ROOT/ViewerUITestDerivedData"
HOST_APP="$HOST_DERIVED/Build/Products/Release/$HOST_APP_NAME"
VIEWER_APP="$VIEWER_DERIVED/Build/Products/Release/$VIEWER_APP_NAME"
HOST_TEST_RESULT="$RELEASE_CACHE_ROOT/SidecarBridgeHostTests.xcresult"
VIEWER_UI_RESULT="$RELEASE_CACHE_ROOT/SidecarBridgeViewerUITests.xcresult"
UPLOAD_DIR="$RELEASE_ARTIFACT_ROOT/notary-upload"
SIGNED_DIR="$RELEASE_ARTIFACT_ROOT/signed"
FINAL_DIR="$RELEASE_ARTIFACT_ROOT/notarized"

mkdir -p "$UPLOAD_DIR"

rm -rf -- "$HOST_TEST_RESULT" "$VIEWER_UI_RESULT"
run_release_tool xcodebuild -quiet \
  -project "$PROJECT_FILE" \
  -scheme SidecarBridgeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$TEST_DERIVED" \
  -resultBundlePath "$HOST_TEST_RESULT" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test

VIEWER_UI_STATUS="skipped"
VIEWER_UI_SKIP_REASON=""
if (( SKIP_VIEWER_UI_TESTS )); then
  VIEWER_UI_SKIP_REASON="explicitly requested with --skip-viewer-ui-tests"
  echo "Viewer UI tests skipped: $VIEWER_UI_SKIP_REASON."
elif sidecarbridge_ui_test_preflight; then
  run_release_tool xcodebuild -quiet \
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
  VIEWER_UI_STATUS="passed"
else
  VIEWER_UI_SKIP_REASON="$UI_TEST_PREFLIGHT_REASON"
  echo "Viewer UI tests skipped: $VIEWER_UI_SKIP_REASON."
  rm -rf -- "$VIEWER_UI_RESULT"
fi

TEST_STATUS="passed"

run_release_tool xcodebuild -quiet \
  -project "$PROJECT_FILE" \
  -scheme SidecarBridgeMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$HOST_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

run_release_tool xcodebuild -quiet \
  -project "$PROJECT_FILE" \
  -scheme SidecarBridgeViewerMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$VIEWER_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ "$VIEWER_UI_STATUS" == "skipped" ]] && (( ! SKIP_VIEWER_UI_TESTS )); then
  echo "Release validation is partial because Viewer UI readiness is unknown; stopping before signing or Apple submission." >&2
  exit 3
fi

python3 "$NOTARIZATION_HELPER" sign "$HOST_APP" --authorized \
  --identity "$SIGNING_IDENTITY" --entitlements "$HOST_ENTITLEMENTS" \
  --generate-entitlement-der
python3 "$NOTARIZATION_HELPER" sign "$VIEWER_APP" --authorized \
  --identity "$SIGNING_IDENTITY" --entitlements "$VIEWER_ENTITLEMENTS" \
  --generate-entitlement-der

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
  local require_ticket="${5:-0}"
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
  if (( require_ticket )); then
    python3 "$NOTARIZATION_HELPER" verify "$app"
  else
    codesign --verify --deep --strict --verbose=2 "$app"
  fi
  echo "Verified ZIP: $zip ($actual_bundle $actual_version/$actual_build)"
}

rm -rf -- "$RELEASE_CACHE_ROOT/VerifySigned"
validate_zip "$HOST_ZIP" "$HOST_APP_NAME" "$HOST_BUNDLE_ID" "$RELEASE_CACHE_ROOT/VerifySigned/Host"
validate_zip "$VIEWER_ZIP" "$VIEWER_APP_NAME" "$VIEWER_BUNDLE_ID" "$RELEASE_CACHE_ROOT/VerifySigned/Viewer"

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
  submit() {
    local zip="$1"
    local submit_args=(submit "$zip" --authorized --wait \
      --auth "$NOTARY_AUTH_MODE" --default-profile notarytool-profile \
      --project-root "$ROOT")
    if [[ -n "${SIDECARBRIDGE_NOTARY_PROFILE:-}" ]]; then
      submit_args+=(--profile "$SIDECARBRIDGE_NOTARY_PROFILE")
    fi
    if [[ -n "$PROJECT_CONFIG_PATH" ]]; then
      submit_args+=(--project-config "$PROJECT_CONFIG_PATH")
    fi
    python3 "$NOTARIZATION_HELPER" "${submit_args[@]}"
  }
  read_submission_result() {
    python3 - "$1" <<'PY'
import json
import re
import sys

status = "Unknown"
submission_id = ""
allowed_statuses = {
    "Accepted", "Invalid", "In Progress", "Uploaded", "Processing",
    "Rejected", "Pending", "Error", "Completed", "Unknown",
}
for line in sys.argv[1].splitlines():
    match = re.fullmatch(r"Apple submission status: ([A-Za-z ]+)", line)
    if match and match.group(1) in allowed_statuses:
        status = match.group(1)
    match = re.fullmatch(
        r"Apple submission ID: ([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})",
        line,
    )
    if match:
        submission_id = match.group(1)
print(json.dumps({"id": submission_id, "status": status}))
PY
  }
  extract_submission_field() {
    python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"
  }
  submit_and_record() {
    local zip="$1"
    local response result status_code
    if response=$(submit "$zip"); then
      status_code=0
    else
      status_code=$?
    fi
    printf '%s\n' "$response"
    result=$(read_submission_result "$response")
    if [[ "$zip" == "$HOST_ZIP" ]]; then
      HOST_NOTARY_ID=$(extract_submission_field "$result" id)
      HOST_NOTARY_STATUS=$(extract_submission_field "$result" status)
    else
      VIEWER_NOTARY_ID=$(extract_submission_field "$result" id)
      VIEWER_NOTARY_STATUS=$(extract_submission_field "$result" status)
    fi
    return "$status_code"
  }
  submit_and_record "$HOST_ZIP"
  submit_and_record "$VIEWER_ZIP"
  [[ "$HOST_NOTARY_STATUS" == "Accepted" && "$VIEWER_NOTARY_STATUS" == "Accepted" ]] || {
    echo "Apple notarization did not accept both apps." >&2
    exit 1
  }
  mkdir -p "$FINAL_DIR"
  for app in "$HOST_APP" "$VIEWER_APP"; do
    python3 "$NOTARIZATION_HELPER" staple "$app"
    python3 "$NOTARIZATION_HELPER" verify "$app"
  done
  HOST_ARTIFACT="$FINAL_DIR/$HOST_ARTIFACT_STEM-Notarized.zip"
  VIEWER_ARTIFACT="$FINAL_DIR/$VIEWER_ARTIFACT_STEM-Notarized.zip"
  ditto -c -k --sequesterRsrc --keepParent "$HOST_APP" \
    "$HOST_ARTIFACT"
  ditto -c -k --sequesterRsrc --keepParent "$VIEWER_APP" \
    "$VIEWER_ARTIFACT"
  ARTIFACT_DIR="$FINAL_DIR"
  ARTIFACT_STATUS="notarized-and-stapled"
  rm -rf -- "$RELEASE_CACHE_ROOT/VerifyNotarized"
  validate_zip "$HOST_ARTIFACT" "$HOST_APP_NAME" "$HOST_BUNDLE_ID" "$RELEASE_CACHE_ROOT/VerifyNotarized/Host" 1
  validate_zip "$VIEWER_ARTIFACT" "$VIEWER_APP_NAME" "$VIEWER_BUNDLE_ID" "$RELEASE_CACHE_ROOT/VerifyNotarized/Viewer" 1
fi

PROJECT_REVISION=$(git rev-parse HEAD)
HOST_SHA=$(shasum -a 256 "$HOST_ARTIFACT" | awk '{print $1}')
VIEWER_SHA=$(shasum -a 256 "$VIEWER_ARTIFACT" | awk '{print $1}')
PROVENANCE="$RELEASE_ARTIFACT_ROOT/provenance.json"
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
