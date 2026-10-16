#!/usr/bin/env bash
set +x
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
EXPECTED_VERSION="1.5"
EXPECTED_BUILD="134"
RELEASE_ROOT="$ROOT/.build/Release$EXPECTED_BUILD"
FINAL_DIR="$RELEASE_ROOT/notarized"
DMG_NAME="ScreenDock-$EXPECTED_VERSION-$EXPECTED_BUILD-macOS.dmg"
FINAL_DMG="$FINAL_DIR/$DMG_NAME"
PROVENANCE="$RELEASE_ROOT/provenance.json"
HOST_APP="$RELEASE_ROOT/HostDerivedData/Build/Products/Release/ScreenDock Host.app"
VIEWER_APP="$RELEASE_ROOT/ViewerDerivedData/Build/Products/Release/ScreenDock Viewer.app"
NOTARIZATION_HELPER="${HOME:?HOME must be set}/.codex/skills/macos-notarization-release/scripts/macos_notarization.py"
CHECK_ONLY=0
STAGING_DIR=""

usage() {
  cat <<'EOF'
Usage: scripts/package-macos-dmg.sh [--check | --help]

Packages the already signed, notarized, and stapled Build 134 Host and Viewer
apps into .build/Release134/notarized/ScreenDock-1.5-134-macOS.dmg. It signs the
DMG but does not submit or staple it. Existing output files are never replaced.

  --check  Verify source apps and resolve the public signing identity without
           creating or signing a DMG.
  --help   Show this help.
EOF
}

die() {
  printf '%s\n' "$1" >&2
  exit 2
}

[[ $# -le 1 ]] || { usage >&2; die "Use at most one option."; }
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; die "Unknown option." ;;
esac

[[ -f "$NOTARIZATION_HELPER" ]] || die "Shared macOS notarization helper is unavailable."
[[ -d "$ROOT/.build" && ! -L "$ROOT/.build" ]] || die "Expected a project-owned .build directory."
[[ -d "$RELEASE_ROOT" && ! -L "$RELEASE_ROOT" ]] || die "Build 134 release directory is missing or is a symlink."
RELEASE_REAL=$(cd "$RELEASE_ROOT" && pwd -P)
[[ "$RELEASE_REAL" == "$ROOT/.build/Release$EXPECTED_BUILD" ]] || die "Build 134 release directory resolves outside the project build path."
[[ -f "$PROVENANCE" && ! -L "$PROVENANCE" ]] || die "Build 134 release provenance is missing or is a symlink."
PROVENANCE_REVISION=$(python3 - "$PROVENANCE" "$EXPECTED_VERSION" "$EXPECTED_BUILD" <<'PY'
import json
import sys

path, expected_version, expected_build = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as source:
        data = json.load(source)
except (OSError, ValueError):
    raise SystemExit("Could not read the Build 134 release provenance JSON.")

notarization = data.get("notarization", {})
if (data.get("version") != expected_version
        or str(data.get("build")) != expected_build
        or notarization.get("status") != "notarized-and-stapled"
        or notarization.get("hostStatus") != "Accepted"
        or notarization.get("viewerStatus") != "Accepted"):
    raise SystemExit("Build 134 provenance does not record accepted, stapled Host and Viewer artifacts.")
revision = data.get("gitRevision")
if not isinstance(revision, str) or not revision:
    raise SystemExit("Build 134 provenance is missing its source revision.")
print(revision)
PY
)

if [[ -L "$FINAL_DIR" ]]; then
  die "The notarized output directory is a symlink; refusing to write outside the release directory."
fi
if [[ -d "$FINAL_DIR" ]]; then
  FINAL_DIR_REAL=$(cd "$FINAL_DIR" && pwd -P)
  [[ "$FINAL_DIR_REAL" == "$RELEASE_REAL/notarized" ]] || die "The notarized output directory resolves outside the release directory."
fi
[[ ! -e "$FINAL_DMG" && ! -L "$FINAL_DMG" ]] || die "Refusing to replace an existing DMG: $FINAL_DMG"

resolve_app_path() {
  local app="$1"
  local expected="$2"
  [[ -d "$app" && ! -L "$app" ]] || die "Expected a built app bundle: $app"
  local resolved
  resolved=$(cd "$app" && pwd -P)
  [[ "$resolved" == "$expected" ]] || die "App bundle does not resolve to its expected Build 134 product path: $app"
  printf '%s\n' "$resolved"
}

validate_app() {
  local app="$1"
  local expected_bundle_id="$2"
  local label="$3"
  local plist="$app/Contents/Info.plist"
  [[ -f "$plist" ]] || die "$label is missing Contents/Info.plist."

  local version build bundle signature_info authority
  version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist")
  build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$plist")
  bundle=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist")
  [[ "$version" == "$EXPECTED_VERSION" && "$build" == "$EXPECTED_BUILD" && "$bundle" == "$expected_bundle_id" ]] || \
    die "$label metadata mismatch: expected $expected_bundle_id $EXPECTED_VERSION ($EXPECTED_BUILD), found $bundle $version ($build)."

  signature_info=$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1) || die "$label has no readable code signature."
  authority=$(printf '%s\n' "$signature_info" | /usr/bin/awk -F= '$1 == "Authority" { print $2; exit }')
  case "$authority" in
    "Developer ID Application:"*) ;;
    *) die "$label is not signed with a Developer ID Application certificate." ;;
  esac

  python3 "$NOTARIZATION_HELPER" verify "$app"
  printf 'Verified %s: %s %s (%s), signer %s\n' "$label" "$bundle" "$version" "$build" "$authority"
}

HOST_APP=$(resolve_app_path "$HOST_APP" "$RELEASE_REAL/HostDerivedData/Build/Products/Release/ScreenDock Host.app")
VIEWER_APP=$(resolve_app_path "$VIEWER_APP" "$RELEASE_REAL/ViewerDerivedData/Build/Products/Release/ScreenDock Viewer.app")
validate_app "$HOST_APP" "com.screendock.host" "ScreenDock Host source"
validate_app "$VIEWER_APP" "com.screendock.viewer" "ScreenDock Viewer source"

DEFAULT_SIGNING_IDENTITY=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | \
  /usr/bin/awk -F '"' '/Developer ID Application:/ { print $2; exit }' || true)
IDENTITY_ARGS=(resolve-signing-identity)
if [[ -n "$DEFAULT_SIGNING_IDENTITY" ]]; then
  IDENTITY_ARGS+=(--default-identity "$DEFAULT_SIGNING_IDENTITY")
fi
SIGNING_IDENTITY=$(python3 "$NOTARIZATION_HELPER" "${IDENTITY_ARGS[@]}")
case "$SIGNING_IDENTITY" in
  "Developer ID Application:"*) ;;
  *) die "The shared helper did not resolve a Developer ID Application identity." ;;
esac

if (( CHECK_ONLY )); then
  printf 'Preflight passed for ScreenDock %s (%s); selected signing identity: %s. No DMG was created or signed.\n' \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" "$SIGNING_IDENTITY"
  exit 0
fi

mkdir -p "$FINAL_DIR"
FINAL_DIR_REAL=$(cd "$FINAL_DIR" && pwd -P)
[[ "$FINAL_DIR_REAL" == "$RELEASE_REAL/notarized" ]] || die "The notarized output directory resolves outside the release directory."
[[ ! -e "$FINAL_DMG" && ! -L "$FINAL_DMG" ]] || die "Refusing to replace an existing DMG: $FINAL_DMG"

STAGING_DIR=$(mktemp -d "$RELEASE_ROOT/DMGStage.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT
  case "$STAGING_DIR" in
    "$RELEASE_REAL"/DMGStage.*) /bin/rm -rf -- "$STAGING_DIR" ;;
  esac
  exit "$status"
}
trap cleanup EXIT

IMAGE_ROOT="$STAGING_DIR/image"
mkdir -p "$IMAGE_ROOT"
/usr/bin/ditto --rsrc --extattr --acl "$HOST_APP" "$IMAGE_ROOT/ScreenDock Host.app"
/usr/bin/ditto --rsrc --extattr --acl "$VIEWER_APP" "$IMAGE_ROOT/ScreenDock Viewer.app"
/bin/ln -s /Applications "$IMAGE_ROOT/Applications"
cat > "$IMAGE_ROOT/Install ScreenDock.txt" <<'EOF'
ScreenDock 1.5 (Build 134)

Quit ScreenDock Host and ScreenDock Viewer. Drag both apps into Applications
and replace both older copies, then launch both apps from Applications.
Instant cursor requires Host and Viewer to use the matching build.

To see the Host's pointer shapes instead of this Mac's instant pointer, open
View > Show ScreenDock Controls (or press Ctrl+Cmd+H), then turn off
Stream > Instant cursor.
EOF

validate_app "$IMAGE_ROOT/ScreenDock Host.app" "com.screendock.host" "ScreenDock Host staged copy"
validate_app "$IMAGE_ROOT/ScreenDock Viewer.app" "com.screendock.viewer" "ScreenDock Viewer staged copy"
[[ -L "$IMAGE_ROOT/Applications" && "$(/usr/bin/readlink "$IMAGE_ROOT/Applications")" == "/Applications" ]] || \
  die "The installer image does not contain the expected /Applications symlink."

TEMP_DMG="$STAGING_DIR/$DMG_NAME"
/usr/bin/hdiutil create -fs HFS+ -volname "ScreenDock 1.5 (Build 134)" \
  -srcfolder "$IMAGE_ROOT" -format UDZO "$TEMP_DMG"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$TEMP_DMG"
/usr/bin/codesign --verify --strict --verbose=2 "$TEMP_DMG"
/usr/bin/hdiutil verify "$TEMP_DMG"

[[ ! -e "$FINAL_DMG" && ! -L "$FINAL_DMG" ]] || die "Refusing to replace an existing DMG: $FINAL_DMG"
/bin/mv -n "$TEMP_DMG" "$FINAL_DMG"
[[ ! -e "$TEMP_DMG" ]] || die "A DMG appeared at the output path during packaging; existing output was preserved."

printf 'Created signed, not-yet-submitted DMG: %s\n' "$FINAL_DMG"
printf 'Source apps: %s and %s (ScreenDock %s, Build %s).\n' \
  "$HOST_APP" "$VIEWER_APP" "$EXPECTED_VERSION" "$EXPECTED_BUILD"
printf 'Source release provenance: %s (revision %s).\n' "$PROVENANCE" "$PROVENANCE_REVISION"
