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
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --check) CHECK_ONLY=1 ;;
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
HOST_APP="$HOST_DERIVED/Build/Products/Release/SidecarBridge.app"
VIEWER_APP="$VIEWER_DERIVED/Build/Products/Release/SidecarBridge Viewer.app"
UPLOAD_DIR="$RELEASE_ROOT/notary-upload"
FINAL_DIR="$RELEASE_ROOT/notarized"
mkdir -p "$UPLOAD_DIR"

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

if (( ! NOTARIZE )); then
  echo "Signed ZIPs are ready under: $UPLOAD_DIR"
  exit 0
fi

notary_args=(--keychain-profile "${SIDECARBRIDGE_NOTARY_PROFILE:-notarytool-profile}")

submit() {
  local zip="$1"
  xcrun notarytool submit "$zip" "${notary_args[@]}" \
    --wait --output-format json --no-progress
}

submit "$HOST_ZIP"
submit "$VIEWER_ZIP"

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

shasum -a 256 "$FINAL_DIR"/*.zip
