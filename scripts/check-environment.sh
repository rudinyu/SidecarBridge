#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
source "$ROOT/scripts/lib/environment.sh"

failures=0
echo "SidecarBridge environment diagnostics (read-only; no signing, network, or GUI actions)."
echo "Repository: $ROOT"
macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
echo "Host: $(uname -s 2>/dev/null || echo unknown) $(uname -m 2>/dev/null || echo unknown), macOS ${macos_version:-unknown}"

if sidecarbridge_resolve_developer_dir; then
  echo "Xcode: $DEVELOPER_DIR"
  "$DEVELOPER_DIR/usr/bin/xcodebuild" -version | sed 's/^/  /'
  if ! sidecarbridge_report_swift_toolchain; then
    failures=$((failures + 1))
  fi
else
  echo "Xcode: unavailable"
  failures=$((failures + 1))
fi

if sidecarbridge_resolve_xcodegen && sidecarbridge_check_xcodegen_version; then
  echo "XcodeGen: $XCODEGEN (version $XCODEGEN_VERSION)"
else
  echo "XcodeGen: unavailable or too old"
  failures=$((failures + 1))
fi

for tool in git python3 plutil xcrun lockf; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s: %s\n' "$tool" "$(command -v "$tool")"
  else
    printf '%s: missing\n' "$tool"
    failures=$((failures + 1))
  fi
done

if command -v python3 >/dev/null 2>&1; then
  python_version="$(python3 --version 2>&1 | sed -E 's/^Python[[:space:]]+//')"
  if python3 - "$python_version" <<'PY'
import re
import sys

match = re.fullmatch(r"(\d+)\.(\d+)(?:\.(\d+))?", sys.argv[1])
raise SystemExit(0 if match and tuple(int(value or 0) for value in match.groups()) >= (3, 9, 0) else 1)
PY
  then
    echo "Python: $python_version (minimum 3.9)"
  else
    echo "Python: ${python_version:-unknown} (requires 3.9 or newer)"
    failures=$((failures + 1))
  fi
fi

for spec in "$ROOT/project.fork.yml" "$ROOT/project.yml"; do
  if [[ -f "$spec" ]]; then
    echo "Project spec: $spec"
  else
    echo "Project spec missing: $spec"
    failures=$((failures + 1))
  fi
done

if git rev-parse --show-toplevel >/dev/null 2>&1; then
  branch="$(git branch --show-current 2>/dev/null || true)"
  revision="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
  status=""
  if ! status="$(git status --short --untracked-files=all 2>&1)"; then
    echo "Git worktree: unknown (git status failed)"
    failures=$((failures + 1))
  else
    if [[ -n "$status" ]]; then
      echo "Git worktree: changes present"
      printf '%s\n' "$status" | sed 's/^/  /'
    else
      echo "Git worktree: clean"
    fi
  fi
  echo "Git branch: ${branch:-detached or unavailable}"
  echo "Git revision: ${revision:-unavailable}"
else
  echo "Git repository: unavailable"
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "Environment diagnostics found $failures issue(s)." >&2
  exit 1
fi
echo "Required local build tools are available."
