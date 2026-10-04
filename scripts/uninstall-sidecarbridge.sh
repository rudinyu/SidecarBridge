#!/bin/bash
# Original SidecarBridge macOS Host/Viewer app and exact per-user state uninstaller.
# macOS Bash 3.2 compatible; dry-run is the default.

REMOVE=0
DRY_RUN_EXPLICIT=0
EXPLICIT_APPS=()
APP_PATHS=()
APP_IDS=()
APP_LABELS=()
STATE_IDS=(io.sidecarbridge.mac io.sidecarbridge.viewer.mac)
STATE_PATHS=()
STATE_KINDS=()
STATE_LABELS=()
STATE_PRESENT=()
BYHOST_EMPTY_IDS=()
ERROR_COUNT=0
PLAN_ERROR_COUNT=0

usage() {
  cat <<'HELP'
原始 SidecarBridge macOS Host/Viewer 卸載工具

用法：
  ./scripts/uninstall-sidecarbridge.sh [--app /absolute/path/SidecarBridge.app ...]
  ./scripts/uninstall-sidecarbridge.sh --dry-run [--app /absolute/path/SidecarBridge.app ...]
  ./scripts/uninstall-sidecarbridge.sh --remove [--app /absolute/path/SidecarBridge.app ...]

預設只預覽。只有明確指定 --remove，並在提示時輸入 REMOVE，才會移除身分驗證通過的 .app bundle 與下列精確的目前使用者狀態。
--app 可重複指定 Applications 資料夾中的精確 .app 路徑。
容器包含 app sandbox 檔案（可能含 Transfers）；不支援以 root 或 sudo 執行。
HELP
}

usage_error() {
  printf '錯誤：%s\n' "$1" >&2
  usage >&2
  exit 64
}

while (($#)); do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --remove)
      REMOVE=1
      shift
      ;;
    --dry-run)
      DRY_RUN_EXPLICIT=1
      shift
      ;;
    --app)
      (($# >= 2)) || usage_error '--app 後面需要一個絕對 .app 路徑。'
      EXPLICIT_APPS+=("$2")
      shift 2
      ;;
    *)
      usage_error "不認得的參數：$1"
      ;;
  esac
done

if ((REMOVE && DRY_RUN_EXPLICIT)); then
  usage_error '--dry-run 不能與 --remove 一起使用。'
fi

contains_newline() {
  case "$1" in
    *$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_absolute_path_syntax() {
  local path=$1 component remaining
  [[ "$path" == /* && "$path" != / && "$path" != *//* ]] || return 1
  contains_newline "$path" && return 1
  [[ "$path" != */ ]] || return 1
  remaining=${path#/}
  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" == */* ]]; then
      component=${remaining%%/*}
      remaining=${remaining#*/}
    else
      component=$remaining
      remaining=''
    fi
    [[ "$component" != . && "$component" != .. ]] || return 1
  done
  return 0
}

no_symlink_components() {
  local path=$1 component current= remaining
  valid_absolute_path_syntax "$path" || return 1
  remaining=${path#/}
  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" == */* ]]; then
      component=${remaining%%/*}
      remaining=${remaining#*/}
    else
      component=$remaining
      remaining=''
    fi
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
  return 0
}

is_under_root() {
  local path=$1 root=$2
  [[ "$path" == "$root"/* ]]
}

is_allowed_install_area() {
  local path=$1
  if is_under_root "$path" /Applications ||
     is_under_root "$path" "$HOME_PATH/Applications" ||
     is_under_root "$path" /Volumes; then
    # External volumes are accepted only when an Applications directory is
    # present in the explicit path. Standard discovery never scans volumes.
    case "$path" in
      /Volumes/?*/Applications/*) return 0 ;;
      /Volumes/*) return 1 ;;
      *) return 0 ;;
    esac
  fi
  return 1
}

is_unsafe_parent_component() {
  local path=$1 parents component remaining
  parents=${path%/*}
  remaining=${parents#/}
  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" == */* ]]; then
      component=${remaining%%/*}
      remaining=${remaining#*/}
    else
      component=$remaining
      remaining=''
    fi
    case "$component" in
      Downloads|Developer|DerivedData|.build|build|Build|Tests|tests|Test|test|Source|source|src|.git|.codex|Codex|ScreenDock|screendock)
        return 0
        ;;
    esac
  done
  return 1
}

read_plist_string() {
  local key=$1 info=$2
  /usr/bin/plutil -extract "$key" raw -o - "$info" 2>/dev/null
}

identify_app() {
  local path=$1 info="$1/Contents/Info.plist"
  local package_type supported_platform executable bundle_id display_name product_name

  [[ "$path" == *.app && -d "$path" && ! -L "$path" ]] || return 1
  [[ -d "$path/Contents" && ! -L "$path/Contents" ]] || return 1
  [[ -f "$info" && ! -L "$info" ]] || return 1
  no_symlink_components "$path" || return 1
  no_symlink_components "$info" || return 1

  package_type=$(read_plist_string CFBundlePackageType "$info") || return 1
  [[ "$package_type" == APPL ]] || return 1
  supported_platform=$(read_plist_string CFBundleSupportedPlatforms.0 "$info") || return 1
  [[ "$supported_platform" == MacOSX ]] || return 1
  executable=$(read_plist_string CFBundleExecutable "$info") || return 1
  bundle_id=$(read_plist_string CFBundleIdentifier "$info") || return 1
  display_name=$(read_plist_string CFBundleDisplayName "$info") || display_name=''
  product_name=$(read_plist_string CFBundleName "$info") || product_name=''

  case "$bundle_id:$display_name:$product_name:$executable" in
    io.sidecarbridge.mac:SidecarBridge:*:SidecarBridge|io.sidecarbridge.mac:*:SidecarBridge:SidecarBridge)
      printf '%s\t%s\n' "$bundle_id" 'SidecarBridge Host'
      return 0
      ;;
    io.sidecarbridge.viewer.mac:'SidecarBridge Viewer':*:'SidecarBridge Viewer'|io.sidecarbridge.viewer.mac:*:'SidecarBridge Viewer':'SidecarBridge Viewer')
      printf '%s\t%s\n' "$bundle_id" 'SidecarBridge Viewer'
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_uuid_suffix() {
  local uuid=$1 uuid_re='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
  [[ "$uuid" =~ $uuid_re ]]
}

add_unique_app() {
  local path=$1 bundle_id=$2 label=$3 existing
  for existing in "${APP_PATHS[@]}"; do
    [[ "$existing" != "$path" ]] || return 0
  done
  APP_PATHS+=("$path")
  APP_IDS+=("$bundle_id")
  APP_LABELS+=("$label")
}

add_app_candidate() {
  local path=$1 source=$2 identity bundle_id label

  if ! valid_absolute_path_syntax "$path" || [[ "$path" != *.app ]] ||
     ! no_symlink_components "$path" || [[ ! -d "$path" ]]; then
    if [[ "$source" == explicit ]]; then
      printf '錯誤：--app 必須是存在、無符號連結且沒有路徑跳脫的精確 .app 路徑：%s\n' "$path" >&2
      return 1
    fi
    return 0
  fi

  if ! is_allowed_install_area "$path" || is_unsafe_parent_component "$path" ||
     is_under_root "$path" "$REPO_ROOT"; then
    if [[ "$source" == explicit ]]; then
      printf '錯誤：拒絕來源碼、建置、測試、資料下載或非 Applications 安裝位置：%s\n' "$path" >&2
      return 1
    fi
    return 0
  fi

  identity=$(identify_app "$path") || {
    if [[ "$source" == explicit ]]; then
      printf '錯誤：.app 的 bundle ID 與顯示名稱／產品名稱未同時符合原始 SidecarBridge Host 或 Viewer：%s\n' "$path" >&2
      return 1
    fi
    return 0
  }
  bundle_id=${identity%%$'\t'*}
  label=${identity#*$'\t'}
  add_unique_app "$path" "$bundle_id" "$label"
  return 0
}

validate_state_parent() {
  local path=$1
  if ! no_symlink_components "$path" ||
     { [[ -e "$path" ]] && [[ ! -d "$path" ]]; } ||
     { [[ -d "$path" ]] && { [[ ! -r "$path" ]] || [[ ! -x "$path" ]]; }; }; then
    printf '錯誤：目前使用者 Library 路徑不存在安全、可檢查的資料夾：%s\n' "$path" >&2
    PLAN_ERROR_COUNT=$((PLAN_ERROR_COUNT + 1))
    return 1
  fi
  return 0
}

add_state_target() {
  local path=$1 kind=$2 label=$3 present=0
  if ! valid_absolute_path_syntax "$path" ||
     ! is_under_root "$path" "$HOME_PATH/Library" ||
     ! no_symlink_components "$path"; then
    printf '錯誤：拒絕有符號連結、不明確或不在目前使用者 Library 內的狀態路徑：%s\n' "$path" >&2
    PLAN_ERROR_COUNT=$((PLAN_ERROR_COUNT + 1))
    return 1
  fi

  if [[ -e "$path" || -L "$path" ]]; then
    case "$kind" in
      file)
        if [[ ! -f "$path" || -L "$path" ]]; then
          printf '錯誤：預期一般檔案，但目標類型不符；拒絕處理：%s\n' "$path" >&2
          PLAN_ERROR_COUNT=$((PLAN_ERROR_COUNT + 1))
          return 1
        fi
        ;;
      directory)
        if [[ ! -d "$path" || -L "$path" ]]; then
          printf '錯誤：預期一般資料夾，但目標類型不符；拒絕處理：%s\n' "$path" >&2
          PLAN_ERROR_COUNT=$((PLAN_ERROR_COUNT + 1))
          return 1
        fi
        ;;
      *)
        printf '錯誤：內部狀態目標類型不明；拒絕處理：%s\n' "$path" >&2
        PLAN_ERROR_COUNT=$((PLAN_ERROR_COUNT + 1))
        return 1
        ;;
    esac
    present=1
  fi

  STATE_PATHS+=("$path")
  STATE_KINDS+=("$kind")
  STATE_LABELS+=("$label")
  STATE_PRESENT+=("$present")
  return 0
}

build_state_plan() {
  local preferences_dir="$HOME_PATH/Library/Preferences"
  local byhost_dir="$HOME_PATH/Library/Preferences/ByHost"
  local caches_dir="$HOME_PATH/Library/Caches"
  local saved_state_dir="$HOME_PATH/Library/Saved Application State"
  local logs_dir="$HOME_PATH/Library/Logs"
  local containers_dir="$HOME_PATH/Library/Containers"
  local parent bundle_id candidate found

  for parent in "$preferences_dir" "$byhost_dir" "$caches_dir" \
    "$saved_state_dir" "$logs_dir" "$containers_dir"; do
    validate_state_parent "$parent" || true
  done
  ((PLAN_ERROR_COUNT == 0)) || return 1

  for bundle_id in "${STATE_IDS[@]}"; do
    add_state_target "$preferences_dir/$bundle_id.plist" file '偏好設定' || true
    found=0
    for candidate in "$byhost_dir/$bundle_id".*.plist; do
      [[ -e "$candidate" || -L "$candidate" ]] || continue
      leaf=${candidate##*/}
      suffix=${leaf#"$bundle_id".}
      suffix=${suffix%.plist}
      if ! is_uuid_suffix "$suffix"; then
        printf '略過非標準 UUID 後綴的 ByHost 項目：%s\n' "$candidate"
        continue
      fi
      found=1
      add_state_target "$candidate" file 'ByHost 偏好設定' || true
    done
    if ((found == 0)); then
      BYHOST_EMPTY_IDS+=("$bundle_id")
    fi
    add_state_target "$caches_dir/$bundle_id" directory '快取' || true
    add_state_target "$saved_state_dir/$bundle_id.savedState" directory 'Saved Application State' || true
    add_state_target "$logs_dir/$bundle_id" directory '記錄' || true
    add_state_target "$containers_dir/$bundle_id" directory 'app sandbox container（含 app 支援檔與 Transfers）' || true
  done
  return 0
}

state_target_is_safe() {
  local path=$1 kind=$2
  valid_absolute_path_syntax "$path" &&
    is_under_root "$path" "$HOME_PATH/Library" &&
    no_symlink_components "$path" || return 1
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 2
  fi
  case "$kind" in
    file) [[ -f "$path" && ! -L "$path" ]] ;;
    directory) [[ -d "$path" && ! -L "$path" ]] ;;
    *) return 1 ;;
  esac
}

check_apps_stopped() {
  local app_check_output bundle_id app_state source host_seen=0 viewer_seen=0 running_found=0
  source='ObjC.import("AppKit"); ObjC.import("Foundation"); function run(argv) { if (argv.length !== 2) { throw new Error("Expected both bundle identifiers."); } return argv.map(function(bid) { var apps = ObjC.unwrap($.NSRunningApplication.runningApplicationsWithBundleIdentifier($(bid))); return bid + "\t" + (apps.length === 0 ? "stopped" : "running"); }).join("\n"); }'

  if ! app_check_output=$(/usr/bin/osascript -l JavaScript -e "$source" "${STATE_IDS[@]}" 2>/dev/null); then
    printf '錯誤：無法透過 AppKit 確認 SidecarBridge Host/Viewer 是否仍在執行；未執行任何清理。\n' >&2
    return 1
  fi

  while IFS=$'\t' read -r bundle_id app_state; do
    case "$bundle_id" in
      "${STATE_IDS[0]}")
        if ((host_seen)); then
          printf '錯誤：AppKit 回傳重複的 Host 狀態；未執行任何清理。\n' >&2
          return 1
        fi
        host_seen=1
        ;;
      "${STATE_IDS[1]}")
        if ((viewer_seen)); then
          printf '錯誤：AppKit 回傳重複的 Viewer 狀態；未執行任何清理。\n' >&2
          return 1
        fi
        viewer_seen=1
        ;;
      *)
        printf '錯誤：AppKit 回傳無法辨識的 bundle ID；未執行任何清理。\n' >&2
        return 1
        ;;
    esac

    case "$app_state" in
      running)
        running_found=1
        printf '仍在執行：%s\n' "$bundle_id" >&2
        ;;
      stopped) ;;
      *)
        printf '錯誤：AppKit 回傳無法辨識的執行狀態；未執行任何清理。\n' >&2
        return 1
        ;;
    esac
  done <<< "$app_check_output"

  if ((host_seen != 1 || viewer_seen != 1)); then
    printf '錯誤：AppKit 未回傳 Host 與 Viewer 的完整狀態；未執行任何清理。\n' >&2
    return 1
  fi
  if ((running_found)); then
    printf '錯誤：請先手動正常結束仍在執行的 app，再重新執行 --remove；未執行 TCC 重設或任何清理。\n' >&2
    return 1
  fi
  return 0
}

CURRENT_UID=$(/usr/bin/id -u 2>/dev/null) || {
  printf '錯誤：無法確認目前使用者。\n' >&2
  exit 1
}
if [[ "$CURRENT_UID" == 0 ]]; then
  printf '錯誤：請以目前登入的非 root 使用者執行，不可使用 sudo。\n' >&2
  exit 1
fi

HOME_PATH=${HOME-}
if [[ -z "$HOME_PATH" ]] || ! valid_absolute_path_syntax "$HOME_PATH" ||
   [[ ! -d "$HOME_PATH" || -L "$HOME_PATH" ]]; then
  printf '錯誤：HOME 無效；拒絕執行。\n' >&2
  exit 1
fi
HOME_OWNER=$(/usr/bin/stat -f '%u' "$HOME_PATH" 2>/dev/null) || HOME_OWNER=''
HOME_PHYSICAL=$(cd "$HOME_PATH" 2>/dev/null && /bin/pwd -P) || HOME_PHYSICAL=''
if [[ "$HOME_OWNER" != "$CURRENT_UID" || "$HOME_PHYSICAL" != "$HOME_PATH" ]] ||
   ! no_symlink_components "$HOME_PATH"; then
  printf '錯誤：HOME 必須是目前使用者擁有、非 root、無符號連結的實體路徑。\n' >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && /bin/pwd -P) || {
  printf '錯誤：無法定位卸載工具所在目錄。\n' >&2
  exit 1
}
REPO_ROOT=${SCRIPT_DIR%/scripts}
if [[ "$REPO_ROOT" == "$SCRIPT_DIR" || ! -d "$REPO_ROOT" ]]; then
  printf '錯誤：無法確認 repository 根目錄；拒絕執行。\n' >&2
  exit 1
fi

for explicit_path in "${EXPLICIT_APPS[@]}"; do
  add_app_candidate "$explicit_path" explicit || exit 1
done

for candidate in /Applications/*.app "$HOME_PATH"/Applications/*.app; do
  [[ -e "$candidate" || -L "$candidate" ]] || continue
  add_app_candidate "$candidate" discovered || exit 1
done

build_state_plan || true
if ((PLAN_ERROR_COUNT > 0)); then
  printf '錯誤：狀態清理範圍無法安全確認；不會執行任何清理。\n' >&2
  exit 1
fi

printf '原始 SidecarBridge macOS app bundle 預覽：\n'
if ((${#APP_PATHS[@]} == 0)); then
  printf '未找到符合原始 Host/Viewer 身分的 app bundle。\n'
fi
for index in "${!APP_PATHS[@]}"; do
  printf '  %s — %s (%s)\n' "${APP_PATHS[$index]}" "${APP_LABELS[$index]}" "${APP_IDS[$index]}"
done

printf '\n精確的目前使用者狀態目標：\n'
for index in "${!STATE_PATHS[@]}"; do
  if [[ "${STATE_PRESENT[$index]}" == 1 ]]; then
    printf '  將移除：%s — %s\n' "${STATE_PATHS[$index]}" "${STATE_LABELS[$index]}"
  else
    printf '  不存在，略過：%s — %s\n' "${STATE_PATHS[$index]}" "${STATE_LABELS[$index]}"
  fi
done
for bundle_id in "${BYHOST_EMPTY_IDS[@]}"; do
  printf '  沒有標準 UUID 後綴的直接 ByHost 檔案：%s.*.plist\n' "$bundle_id"
done

printf '\nmacOS per-app TCC 重設請求（Local Network 不會被重設）：\n'
for bundle_id in "${STATE_IDS[@]}"; do
  printf '  tccutil reset All %s\n' "$bundle_id"
done

if ((!REMOVE)); then
  printf '\n目前是預覽模式；未刪除任何項目。確認清單正確後，使用 --remove 並輸入 REMOVE。\n'
  exit 0
fi

printf '\n警告：確認後會永久移除以上 .app bundle、精確列出的偏好／快取／狀態路徑及 app sandbox containers。Containers 可能含收到的檔案與 Transfers。\n'
printf '全域 Application Support/SidecarBridge、Keychain、iPad 資料及其他資料不在範圍；tccutil 只重設 macOS 支援的逐 app TCC 項目，不會重設 Local Network。\n'
if [[ ! -t 0 ]]; then
  printf '錯誤：--remove 必須在互動終端中執行並完成文字確認。\n' >&2
  exit 64
fi
printf '輸入 REMOVE 確認：'
IFS= read -r confirmation || confirmation=''
if [[ "$confirmation" != REMOVE ]]; then
  printf '未確認；沒有刪除 app bundle。\n'
  exit 0
fi

if ! check_apps_stopped; then
  exit 1
fi

for bundle_id in "${STATE_IDS[@]}"; do
  if /usr/bin/tccutil reset All "$bundle_id"; then
    printf '已要求 macOS 重設逐 app TCC 項目：%s\n' "$bundle_id"
  else
    printf '錯誤：tccutil 無法重設逐 app TCC 項目：%s\n' "$bundle_id" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
done

for index in "${!STATE_PATHS[@]}"; do
  state_path=${STATE_PATHS[$index]}
  state_kind=${STATE_KINDS[$index]}
  state_status=0
  state_target_is_safe "$state_path" "$state_kind" || state_status=$?
  if ((state_status == 2)); then
    printf '已不存在，略過：%s\n' "$state_path"
    continue
  elif ((state_status != 0)); then
    printf '錯誤：清理前狀態路徑驗證失敗，保留：%s\n' "$state_path" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi
  if /bin/rm -rf "$state_path"; then
    printf '已移除狀態：%s\n' "$state_path"
  else
    printf '錯誤：無法完整移除狀態路徑：%s\n' "$state_path" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
done

for index in "${!APP_PATHS[@]}"; do
  app_path=${APP_PATHS[$index]}
  expected_id=${APP_IDS[$index]}
  current_identity=$(identify_app "$app_path") || current_identity=''
  current_id=${current_identity%%$'\t'*}
  if [[ -z "$current_identity" || "$current_id" != "$expected_id" ]] ||
     ! is_allowed_install_area "$app_path" || is_unsafe_parent_component "$app_path" ||
     is_under_root "$app_path" "$REPO_ROOT"; then
    printf '錯誤：刪除前身分驗證失敗，保留：%s\n' "$app_path" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi
  if /bin/rm -rf "$app_path"; then
    printf '已移除 app bundle：%s\n' "$app_path"
  else
    printf '錯誤：無法完整移除 app bundle，請檢查路徑：%s\n' "$app_path" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
done

if ((ERROR_COUNT > 0)); then
  printf '部分 app bundle、使用者狀態或 TCC 重設未完成；請依錯誤訊息檢查。\n' >&2
  exit 1
fi
printf '完成。Keychain、全域 SidecarBridge Application Support、iPad 資料及登入項目狀態未由此工具變更；Local Network 權限不會由 tccutil 重設。\n'
