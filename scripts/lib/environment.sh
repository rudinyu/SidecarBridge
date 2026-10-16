#!/usr/bin/env bash

# Shared, read-only toolchain discovery for SidecarBridge's macOS workflows.

sidecarbridge_is_full_xcode() {
  local candidate="${1%/}"
  [[ -n "$candidate" && -x "$candidate/usr/bin/xcodebuild" ]] || return 1
  [[ -f "$candidate/../Info.plist" ]] || return 1
  [[ -d "$candidate/Platforms/MacOSX.platform/Developer/SDKs" ]] || return 1
  "$candidate/usr/bin/xcodebuild" -version >/dev/null 2>&1
}

sidecarbridge_resolve_developer_dir() {
  local candidate app
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    candidate="${DEVELOPER_DIR%/}"
    if ! sidecarbridge_is_full_xcode "$candidate"; then
      echo "DEVELOPER_DIR is set but is not a usable full Xcode developer directory: $DEVELOPER_DIR" >&2
      return 2
    fi
  else
    candidate=""
    if sidecarbridge_is_full_xcode /Applications/Xcode.app/Contents/Developer; then
      candidate="/Applications/Xcode.app/Contents/Developer"
    else
      for app in /Applications/Xcode*.app; do
        [[ -d "$app" ]] || continue
        if sidecarbridge_is_full_xcode "$app/Contents/Developer"; then
          candidate="$app/Contents/Developer"
          break
        fi
      done
    fi
    if [[ -z "$candidate" ]]; then
      candidate="$(xcode-select -p 2>/dev/null || true)"
    fi
    if ! sidecarbridge_is_full_xcode "$candidate"; then
      echo "No usable full Xcode developer directory is selected. Set DEVELOPER_DIR to a full Xcode Contents/Developer path or select one with xcode-select." >&2
      return 2
    fi
  fi

  DEVELOPER_DIR="$candidate"
  export DEVELOPER_DIR
}

sidecarbridge_resolve_xcodegen() {
  local candidate=""
  if [[ -n "${XCODEGEN_BIN:-}" ]]; then
    if [[ -f "$XCODEGEN_BIN" && -x "$XCODEGEN_BIN" ]]; then
      candidate="$XCODEGEN_BIN"
    elif [[ "$XCODEGEN_BIN" != */* ]] && command -v "$XCODEGEN_BIN" >/dev/null 2>&1; then
      candidate="$(command -v "$XCODEGEN_BIN")"
    else
      echo "XCODEGEN_BIN is not executable or available on PATH: $XCODEGEN_BIN" >&2
      return 2
    fi
  elif command -v xcodegen >/dev/null 2>&1; then
    candidate="$(command -v xcodegen)"
  elif [[ -f "$ROOT/.tools/xcodegen/bin/xcodegen" && -x "$ROOT/.tools/xcodegen/bin/xcodegen" ]]; then
    candidate="$ROOT/.tools/xcodegen/bin/xcodegen"
  elif [[ -f "$ROOT/.tools/xcodegen/xcodegen/bin/xcodegen" && -x "$ROOT/.tools/xcodegen/xcodegen/bin/xcodegen" ]]; then
    candidate="$ROOT/.tools/xcodegen/xcodegen/bin/xcodegen"
  elif [[ -f "$ROOT/.build/Tools/XcodeGen/xcodegen" && -x "$ROOT/.build/Tools/XcodeGen/xcodegen" ]]; then
    candidate="$ROOT/.build/Tools/XcodeGen/xcodegen"
  elif [[ -f "$ROOT/.build/Tools/XcodeGen/xcodegen/bin/xcodegen" && -x "$ROOT/.build/Tools/XcodeGen/xcodegen/bin/xcodegen" ]]; then
    candidate="$ROOT/.build/Tools/XcodeGen/xcodegen/bin/xcodegen"
  elif [[ -f "$ROOT/.build/Tools/XcodeGen/bin/xcodegen" && -x "$ROOT/.build/Tools/XcodeGen/bin/xcodegen" ]]; then
    candidate="$ROOT/.build/Tools/XcodeGen/bin/xcodegen"
  else
    echo "XcodeGen is unavailable. Set XCODEGEN_BIN, put it on PATH, or install it under .tools/xcodegen/." >&2
    return 2
  fi

  XCODEGEN="$candidate"
  export XCODEGEN
}

sidecarbridge_report_swift_toolchain() {
  local swift_path

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is unavailable on PATH." >&2
    return 1
  fi
  if ! swift_path="$(xcrun --find swift 2>/dev/null)" || [[ ! -x "$swift_path" ]]; then
    echo "Swift could not be resolved from selected Xcode: $DEVELOPER_DIR" >&2
    return 1
  fi

  echo "Swift: $swift_path"
  "$swift_path" --version | sed 's/^/  /'
}

sidecarbridge_check_xcodegen_version() {
  local version output
  output="$("$XCODEGEN" --version 2>/dev/null || true)"
  version="$(printf '%s\n' "$output" | tail -n 1 | sed -E 's/^[Vv]ersion:[[:space:]]*//; s/[[:space:]]//g')"
  if [[ -z "$version" ]] || ! python3 - "$version" <<'PY'
import re
import sys

def parts(value):
    match = re.fullmatch(r"(\d+)\.(\d+)(?:\.(\d+))?", value)
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())

actual = parts(sys.argv[1])
minimum = (2, 46, 0)
raise SystemExit(0 if actual is not None and actual >= minimum else 1)
PY
  then
    echo "XcodeGen 2.46.0 or newer is required; found ${version:-unknown}." >&2
    return 2
  fi
  XCODEGEN_VERSION="$version"
}
