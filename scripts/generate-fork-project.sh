#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PROJECT_PATH="$ROOT/SidecarBridgeFork.xcodeproj"
SPEC_PATH="$ROOT/project.fork.yml"

if [[ -n "${XCODEGEN_BIN:-}" ]]; then
  if [[ -f "$XCODEGEN_BIN" && -x "$XCODEGEN_BIN" ]]; then
    XCODEGEN="$XCODEGEN_BIN"
  elif [[ "$XCODEGEN_BIN" != */* ]] && command -v "$XCODEGEN_BIN" >/dev/null 2>&1; then
    XCODEGEN=$(command -v "$XCODEGEN_BIN")
  else
    echo "XCODEGEN_BIN is not executable or available on PATH: $XCODEGEN_BIN" >&2
    exit 2
  fi
elif [[ -f "$ROOT/.build/Tools/XcodeGen/xcodegen" && -x "$ROOT/.build/Tools/XcodeGen/xcodegen" ]]; then
  XCODEGEN="$ROOT/.build/Tools/XcodeGen/xcodegen"
elif [[ -f "$ROOT/.build/Tools/XcodeGen/xcodegen/bin/xcodegen" && -x "$ROOT/.build/Tools/XcodeGen/xcodegen/bin/xcodegen" ]]; then
  XCODEGEN="$ROOT/.build/Tools/XcodeGen/xcodegen/bin/xcodegen"
elif [[ -f "$ROOT/.build/Tools/XcodeGen/bin/xcodegen" && -x "$ROOT/.build/Tools/XcodeGen/bin/xcodegen" ]]; then
  XCODEGEN="$ROOT/.build/Tools/XcodeGen/bin/xcodegen"
elif command -v xcodegen >/dev/null 2>&1; then
  XCODEGEN=$(command -v xcodegen)
else
  echo "XcodeGen is required. Set XCODEGEN_BIN or install it under .build/Tools/XcodeGen/." >&2
  exit 2
fi

[[ -f "$SPEC_PATH" ]] || { echo "Fork project spec is missing: $SPEC_PATH" >&2; exit 2; }

# Never let a failed generation be mistaken for a usable previous project.
rm -rf -- "$PROJECT_PATH"
"$XCODEGEN" generate --spec "$SPEC_PATH"
[[ -f "$PROJECT_PATH/project.pbxproj" ]] || {
  echo "XcodeGen did not create the expected project: $PROJECT_PATH" >&2
  exit 1
}

echo "Generated $PROJECT_PATH from project.fork.yml with $XCODEGEN"
