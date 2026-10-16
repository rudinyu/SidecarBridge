#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if (( $# == 0 )); then
  echo "Usage: scripts/with-build-lock.sh command [arguments...]" >&2
  exit 2
fi

# Entrypoints pass through this wrapper once. Their child scripts inherit the
# root marker so generation does not try to acquire the same lock recursively.
if [[ "${SIDECARBRIDGE_BUILD_LOCK_ROOT:-}" == "$ROOT" ]]; then
  exec "$@"
fi

BUILD_DIR="$ROOT/.build"
LOCK_DIR="$BUILD_DIR/locks"
LOCK_FILE="$LOCK_DIR/mutations.lock"
if [[ -L "$BUILD_DIR" || ( -e "$BUILD_DIR" && ! -d "$BUILD_DIR" ) ]]; then
  echo "Refusing to use non-directory or symlinked build state: $BUILD_DIR" >&2
  exit 2
fi
if [[ -L "$LOCK_DIR" || ( -e "$LOCK_DIR" && ! -d "$LOCK_DIR" ) ]]; then
  echo "Refusing to use non-directory or symlinked build lock directory: $LOCK_DIR" >&2
  exit 2
fi
mkdir -p "$LOCK_DIR"
if [[ -L "$LOCK_FILE" || ( -e "$LOCK_FILE" && ! -f "$LOCK_FILE" ) ]]; then
  echo "Refusing to use non-regular or symlinked build lock file: $LOCK_FILE" >&2
  exit 2
fi

# Fail fast instead of letting two commands queue behind a long build. All
# callers share this lock, including direct project generation and --clean.
/usr/bin/lockf -k -t 0 "$LOCK_FILE" \
  /usr/bin/env SIDECARBRIDGE_BUILD_LOCK_ROOT="$ROOT" "$@"
