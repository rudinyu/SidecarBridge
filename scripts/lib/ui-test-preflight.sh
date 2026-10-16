#!/usr/bin/env bash

# Requires a fresh interactive confirmation because macOS does not provide a
# reliable, non-privileged command-line check for lock/authentication state and
# Xcode's UI Automation TCC grant.
sidecarbridge_ui_test_preflight() {
  local console_user response
  UI_TEST_PREFLIGHT_STATUS="unknown"
  UI_TEST_PREFLIGHT_REASON=""

  if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" ]]; then
    UI_TEST_PREFLIGHT_REASON="the current host is not macOS"
    echo "Viewer UI tests skipped: $UI_TEST_PREFLIGHT_REASON." >&2
    return 1
  fi

  console_user="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
  if [[ -z "$console_user" ]]; then
    UI_TEST_PREFLIGHT_REASON="the active console user could not be verified"
    echo "Viewer UI tests skipped: $UI_TEST_PREFLIGHT_REASON." >&2
    return 1
  fi
  case "$console_user" in
    root|loginwindow|_mbsetupuser)
      UI_TEST_PREFLIGHT_REASON="there is no logged-in interactive desktop user (console reports $console_user)"
      echo "Viewer UI tests skipped: $UI_TEST_PREFLIGHT_REASON." >&2
      return 1
      ;;
  esac

  if [[ ! -r /dev/tty ]]; then
    UI_TEST_PREFLIGHT_REASON="fresh interactive readiness confirmation is unavailable because there is no controlling terminal"
    echo "Viewer UI tests skipped: $UI_TEST_PREFLIGHT_REASON." >&2
    return 1
  fi

  cat >&2 <<'EOF'
Viewer UI test preflight: confirm the active macOS desktop is unlocked, no
password/Touch ID/approval prompt is active, and UI Automation is already
approved for Xcode/Xcode Helper. Type RUN UI TESTS to start the UI runner.
Any other response skips the UI suite.
EOF
  if ! IFS= read -r response </dev/tty; then
    UI_TEST_PREFLIGHT_REASON="the operator did not provide a fresh readiness confirmation"
    echo "Viewer UI tests skipped: $UI_TEST_PREFLIGHT_REASON." >&2
    return 1
  fi
  if [[ "$response" != "RUN UI TESTS" ]]; then
    UI_TEST_PREFLIGHT_REASON="the operator did not confirm unlocked desktop, no active authentication prompt, and existing UI Automation approval"
    echo "Viewer UI tests skipped: $UI_TEST_PREFLIGHT_REASON." >&2
    return 1
  fi

  UI_TEST_PREFLIGHT_STATUS="operator-confirmed"
  UI_TEST_PREFLIGHT_REASON="fresh interactive confirmation received"
  echo "Viewer UI preflight ready: $UI_TEST_PREFLIGHT_REASON." >&2
}
