#!/bin/bash
# ScreenDock Host and Viewer user-run uninstaller. macOS built-ins only; Bash 3.2 compatible.
REMOVE=0
YES=0
INCLUDE_DEBUG=0
DRY_RUN_EXPLICIT=0
EXPLICIT_APPS=()
APP_PATHS=()
APP_IDS=()
TARGET_IDS=(com.screendock.host com.screendock.viewer)
DEFAULTS_DOMAINS=(com.screendock.host com.screendock.viewer)
CLEAN_PATHS=()
ERROR_COUNT=0

usage() {
  cat <<'HELP'
ScreenDock Host/Viewer 卸載工具（macOS）

用法：
  ./scripts/uninstall-screendock.sh [--include-debug] [--app /absolute/path/ScreenDock.app ...]
  ./scripts/uninstall-screendock.sh --dry-run [--include-debug] [--app /absolute/path/ScreenDock.app ...]
  ./scripts/uninstall-screendock.sh --remove [--yes] [--include-debug] [--app /absolute/path/ScreenDock.app ...]

預設只預覽。只有 --remove 會執行清理；未加 --yes 時需輸入 REMOVE 確認。
--yes 僅可與 --remove 一起使用。--app 可重複指定標準搜尋位置以外的 ScreenDock .app。
--dry-run 是預設模式，不能與 --remove 一起使用。
--include-debug 會把 Debug Host/Viewer 的程式、偏好及 ScreenDock Debug 資料納入。

不支援以 sudo 執行。刪除 /Applications 內的程式若遭拒，請依輸出手動處理。
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
    --yes)
      YES=1
      shift
      ;;
    --include-debug)
      INCLUDE_DEBUG=1
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

if ((YES && !REMOVE)); then
  usage_error '--yes 只能與 --remove 一起使用。'
fi
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

add_unique_app() {
  local path=$1 bundle_id=$2 existing
  for existing in "${APP_PATHS[@]}"; do
    [[ "$existing" != "$path" ]] || return 0
  done
  APP_PATHS+=("$path")
  APP_IDS+=("$bundle_id")
}

read_bundle_id() {
  local path=$1 info="$1/Contents/Info.plist"
  [[ -d "$path" && ! -L "$path" && -f "$info" && ! -L "$info" ]] || return 1
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info" 2>/dev/null
}

is_allowed_id() {
  case "$1" in
    com.screendock.host|com.screendock.viewer) return 0 ;;
    com.screendock.host.debug|com.screendock.viewer.debug)
      ((INCLUDE_DEBUG)) && return 0
      return 2
      ;;
    *) return 1 ;;
  esac
}

add_app_candidate() {
  local path=$1 source=$2 bundle_id status
  if ! valid_absolute_path_syntax "$path" || [[ "$path" != *.app ]] ||
     ! no_symlink_components "$path" || [[ ! -d "$path" ]]; then
    if [[ "$source" == explicit ]]; then
      printf '錯誤：--app 路徑不存在或含有符號連結、路徑跳脫或不安全元件：%s\n' "$path" >&2
      return 1
    fi
    case "${path##*/}" in
      *ScreenDock*|*screendock*) printf '略過不安全的 ScreenDock 名稱候選（需使用實體路徑）：%s\n' "$path" ;;
    esac
    return 0
  fi
  bundle_id=$(read_bundle_id "$path") || {
    if [[ "$source" == explicit ]]; then
      printf '錯誤：無法從 .app/Contents/Info.plist 讀取 CFBundleIdentifier：%s\n' "$path" >&2
      return 1
    fi
    return 0
  }
  is_allowed_id "$bundle_id"
  status=$?
  if ((status == 2)); then
    if [[ "$source" == explicit ]]; then
      printf '錯誤：%s 是 Debug app；請加上 --include-debug。\n' "$path" >&2
      return 1
    fi
    return 0
  elif ((status != 0)); then
    if [[ "$source" == explicit ]]; then
      printf '錯誤：CFBundleIdentifier 不在 ScreenDock 白名單內：%s\n' "$bundle_id" >&2
      return 1
    fi
    return 0
  fi
  add_unique_app "$path" "$bundle_id"
  return 0
}

for explicit_path in "${EXPLICIT_APPS[@]}"; do
  if ! add_app_candidate "$explicit_path" explicit; then
    exit 1
  fi
done

for candidate in /Applications/*.app "$HOME_PATH"/Applications/*.app /Volumes/*/Applications/*.app; do
  [[ -e "$candidate" || -L "$candidate" ]] || continue
  add_app_candidate "$candidate" discovered || exit 1
done

if ((INCLUDE_DEBUG)); then
  TARGET_IDS+=(com.screendock.host.debug com.screendock.viewer.debug)
  DEFAULTS_DOMAINS+=(com.screendock.host.debug com.screendock.viewer.debug \
    com.screendock.debug.host com.screendock.debug.viewer)
fi

# Build the fixed per-user cleanup allowlist. No recursive search is used.
for bundle_id in "${TARGET_IDS[@]}"; do
  CLEAN_PATHS+=(
    "$HOME_PATH/Library/Preferences/$bundle_id.plist"
    "$HOME_PATH/Library/Caches/$bundle_id"
    "$HOME_PATH/Library/Saved Application State/$bundle_id.savedState"
    "$HOME_PATH/Library/Logs/$bundle_id"
    "$HOME_PATH/Library/Containers/$bundle_id"
    "$HOME_PATH/Library/Application Scripts/$bundle_id"
  )
done
CLEAN_PATHS+=("$HOME_PATH/Library/Application Support/ScreenDock")
if ((INCLUDE_DEBUG)); then
  CLEAN_PATHS+=(
    "$HOME_PATH/Library/Preferences/com.screendock.debug.host.plist"
    "$HOME_PATH/Library/Preferences/com.screendock.debug.viewer.plist"
  )
  CLEAN_PATHS+=("$HOME_PATH/Library/Application Support/ScreenDock Debug")
fi

is_uuid_suffix() {
  local uuid=$1 uuid_re='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
  [[ "$uuid" =~ $uuid_re ]]
}

add_byhost_preferences() {
  local domain=$1 byhost="$HOME_PATH/Library/Preferences/ByHost" candidate leaf suffix
  [[ -d "$byhost" ]] || return 0
  for candidate in "$byhost/$domain".*.plist; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    leaf=${candidate##*/}
    suffix=${leaf#"$domain".}
    suffix=${suffix%.plist}
    is_uuid_suffix "$suffix" || continue
    CLEAN_PATHS+=("$candidate")
  done
}
for domain in "${DEFAULTS_DOMAINS[@]}"; do
  add_byhost_preferences "$domain"
done

safe_data_target() {
  local target=$1
  case "$target" in
    "$HOME_PATH"/Library/Preferences/*|\
    "$HOME_PATH"/Library/Caches/*|\
    "$HOME_PATH"/Library/Saved\ Application\ State/*|\
    "$HOME_PATH"/Library/Logs/*|\
    "$HOME_PATH"/Library/Containers/*|\
    "$HOME_PATH"/Library/Application\ Scripts/*|\
    "$HOME_PATH"/Library/Application\ Support/ScreenDock|\
    "$HOME_PATH"/Library/Application\ Support/ScreenDock\ Debug) ;;
    *) return 1 ;;
  esac
  valid_absolute_path_syntax "$target" && no_symlink_components "${target%/*}"
}

inspect_path() {
  local path=$1 output status
  output=$(LC_ALL=C /usr/bin/stat -f '%HT' "$path" 2>&1)
  status=$?
  if ((status == 0)); then
    printf 'present'
    return 0
  fi
  case "$output" in
    *"No such file or directory"*)
      printf 'missing'
      return 0
      ;;
    *)
      printf 'stat exit %d: %s' "$status" "$output"
      return 1
      ;;
  esac
}

print_plan() {
  printf '模式：%s\n' "$([[ $REMOVE == 1 ]] && printf '實際清理' || printf '預覽（不寫入、不重設權限、不停止 app）')"
  if ((${#APP_PATHS[@]})); then
    printf '\n將辨識的 ScreenDock app bundle：\n'
    local i
    for ((i=0; i<${#APP_PATHS[@]}; i++)); do
      printf '  %s  [%s]\n' "${APP_PATHS[$i]}" "${APP_IDS[$i]}"
    done
  else
    printf '\n在標準位置未找到 ScreenDock app；仍會檢查精確的使用者資料路徑。非標準安裝請加 --app。\n'
  fi
  printf '\n精確的使用者資料清理白名單（路徑不存在時略過）：\n'
  local target
  for target in "${CLEAN_PATHS[@]}"; do
    printf '  %s\n' "$target"
  done
  printf '\n精確偏好 domain：\n'
  for domain in "${DEFAULTS_DOMAINS[@]}"; do printf '  %s\n' "$domain"; done
  printf '\n將處理的系統與 Keychain 項目：\n'
  for bundle_id in "${TARGET_IDS[@]}"; do printf '  tccutil reset All %s（只限此 app ID）\n' "$bundle_id"; done
  for service in $(keychain_services); do printf '  舊版 file Keychain generic-password service：%s\n' "$service"; done
  printf '  Data Protection Keychain、Local Network 授權及 Host 登入項目需依文件手動處理。\n'
  printf '\n重要：清理會永久刪除收到的檔案（Transfers）。完整清單請先查看 docs/UNINSTALL.md。\n'
}

# Output only fixed, allowlisted service names (Bash 3.2 has no associative arrays).
keychain_services() {
  printf '%s\n' com.screendock.host.trusted-devices com.screendock.viewer.trusted-devices
  if ((INCLUDE_DEBUG)); then
    printf '%s\n' com.screendock.debug.host.trusted-devices com.screendock.debug.viewer.trusted-devices
  fi
}

jxa_process_action() {
  local bundle_id=$1 action=$2 source result
  # bundle_id only comes from TARGET_IDS, never from user input.
  source='ObjC.import("AppKit"); ObjC.import("Foundation"); function run(argv) { var bid = argv[0]; var action = argv[1]; var running = function(){ return ObjC.unwrap($.NSRunningApplication.runningApplicationsWithBundleIdentifier($(bid))); }; var apps = running(); if (action === "terminate") { apps.forEach(function(app){ app.terminate(); }); var deadline = Date.now() + 15000; while (Date.now() < deadline) { if (running().length === 0) break; $.NSThread.sleepForTimeInterval(0.25); } apps = running(); } return apps.length === 0 ? "NONE" : "RUNNING=" + apps.length; }'
  result=$(/usr/bin/osascript -l JavaScript -e "$source" "$bundle_id" "$action" 2>/dev/null) || return 1
  printf '%s' "$result"
}

remove_legacy_keychain_service() {
  local service=$1 attempt status deleted=0
  for ((attempt=1; attempt<=1024; attempt++)); do
    /usr/bin/security delete-generic-password -s "$service" >/dev/null 2>&1
    status=$?
    if ((status == 0)); then
      deleted=1
      continue
    elif ((status == 44)); then
      break
    else
      report_error "security delete-generic-password -s $service（結束碼 $status）"
      return 1
    fi
  done

  # Confirm that the exact service has no remaining legacy file-Keychain items.
  /usr/bin/security find-generic-password -s "$service" >/dev/null 2>&1
  status=$?
  if ((status == 44)); then
    if ((deleted)); then printf '已處理並確認舊版 file Keychain service：%s\n' "$service"; fi
    return 0
  elif ((status == 0)); then
    report_error "Keychain service $service 在 1024 次刪除上限後仍有項目；請在 Keychain Access 檢查。"
  else
    report_error "無法確認 Keychain service $service 是否已清除（結束碼 $status）。"
  fi
  return 1
}

report_error() {
  ERROR_COUNT=$((ERROR_COUNT + 1))
  printf '失敗：%s\n' "$1" >&2
}

if ((!REMOVE)); then
  print_plan
  printf '\n預覽未執行任何清理。加入 --remove 才會執行。\n'
  for bundle_id in "${TARGET_IDS[@]}"; do
    process_state=$(jxa_process_action "$bundle_id" inspect 2>/dev/null) || process_state='無法檢查（預覽仍未停止 app）'
    printf '執行中狀態 %s：%s\n' "$bundle_id" "$process_state"
  done
  exit 0
fi

print_plan
printf '\n不可逆提醒：收到的檔案將被永久刪除。請先在 Host 將 Automatic startup 關閉，並在 Host 和 Viewer 各自執行 Forget All；也請先完成 docs/UNINSTALL.md 的 Keychain 與隱私權檢查。\n'
if ((!YES)); then
  printf '輸入 REMOVE 才會繼續：'
  IFS= read -r confirmation || confirmation=''
  [[ "$confirmation" == REMOVE ]] || {
    printf '已取消；沒有執行清理。\n'
    exit 0
  }
fi

# Ask only the exact selected bundle IDs to terminate politely, then fail closed
# before any TCC, Keychain, defaults, app-bundle, or data deletion if one remains.
for bundle_id in "${TARGET_IDS[@]}"; do
  process_state=$(jxa_process_action "$bundle_id" terminate 2>/dev/null) || {
    printf '錯誤：無法透過 AppKit 查詢/停止 %s；未開始刪除資料。\n' "$bundle_id" >&2
    exit 1
  }
  if [[ "$process_state" != NONE ]]; then
    printf '錯誤：%s 仍在執行（%s）；為保護資料，未開始刪除。\n' "$bundle_id" "$process_state" >&2
    exit 1
  fi
done

# Reset supported per-app TCC services before removing app bundles. Local Network
# has no supported reset-to-undetermined operation and is handled in the report.
for bundle_id in "${TARGET_IDS[@]}"; do
  if /usr/bin/tccutil reset All "$bundle_id" >/dev/null 2>&1; then
    printf '已要求 macOS 重設此 app 的支援 TCC 權限：%s\n' "$bundle_id"
  else
    status=$?
    report_error "tccutil reset All $bundle_id（結束碼 $status）"
  fi
done

# Delete only exact defaults domains. Check presence first so an absent domain
# is not misreported as a cleanup failure.
for domain in "${DEFAULTS_DOMAINS[@]}"; do
  if /usr/bin/defaults read "$domain" >/dev/null 2>&1; then
    if /usr/bin/defaults delete "$domain" >/dev/null 2>&1; then
      printf '已刪除偏好 domain：%s\n' "$domain"
    else
      status=$?
      report_error "defaults delete $domain（結束碼 $status）"
    fi
  fi
done

# Remove only the legacy file-Keychain items for exact ScreenDock services.
# Data Protection Keychain contents cannot be verified or removed by this CLI.
while IFS= read -r service; do
  remove_legacy_keychain_service "$service"
done < <(keychain_services)

for target in "${CLEAN_PATHS[@]}"; do
  path_state=$(inspect_path "$target")
  path_status=$?
  if ((path_status != 0)); then
    report_error "無法檢查資料路徑 $target（$path_state）；拒絕將未知狀態當作不存在。"
    continue
  fi
  [[ "$path_state" != missing ]] || continue
  if ! safe_data_target "$target" || [[ -L "$target" ]]; then
    report_error "拒絕刪除不安全或符號連結路徑：$target"
    continue
  fi
  if /bin/rm -rf "$target"; then
    printf '已刪除：%s\n' "$target"
  else
    status=$?
    report_error "無法刪除 $target（結束碼 $status）；可能需要 Finder/管理員手動處理，請勿用 sudo 執行整份腳本。"
  fi
done

for ((i=0; i<${#APP_PATHS[@]}; i++)); do
  app_path=${APP_PATHS[$i]}
  expected_id=${APP_IDS[$i]}
  path_state=$(inspect_path "$app_path")
  path_status=$?
  if ((path_status != 0)); then
    report_error "無法檢查 app bundle 路徑 $app_path（$path_state）；拒絕將未知狀態當作不存在。"
    continue
  fi
  if [[ "$path_state" == missing ]]; then
    printf 'app bundle 已不存在，略過：%s\n' "$app_path"
    continue
  fi
  if ! no_symlink_components "$app_path" || [[ -L "$app_path" || ! -d "$app_path" ]]; then
    report_error "app bundle 路徑在刪除前變得不安全：$app_path"
    continue
  fi
  current_id=$(read_bundle_id "$app_path") || current_id=''
  if [[ "$current_id" != "$expected_id" ]]; then
    report_error "app bundle 身分在刪除前改變（預期 $expected_id，讀到 ${current_id:-無法讀取}）：$app_path"
    continue
  fi
  if /bin/rm -rf "$app_path"; then
    printf '已刪除 app bundle：%s\n' "$app_path"
  else
    status=$?
    report_error "無法刪除 app bundle $app_path（結束碼 $status）；請手動移除或依系統管理政策處理，不會自動使用 sudo。"
  fi
done

printf '\n清理摘要：自動作業失敗 %d 項。\n' "$ERROR_COUNT"
printf '本工具無法驗證的手動項目：確認 Host Automatic startup/Login Items 已關閉或移除、Data Protection Keychain 身分/信任項目已檢查，以及 Local Network 權限已撤銷。\n'
printf 'Host 螢幕錄製、輔助使用與 PostEvent 等受支援 TCC 權限已嘗試逐 app reset；不能據此宣稱所有系統隱私記錄已清除。\n'
printf 'Local Network 沒有支援的 reset-to-undetermined；請到 System Settings > Privacy & Security > Local Network 撤銷 ScreenDock 項目，歷史項目可能仍顯示。\n'
printf '請依 docs/UNINSTALL.md 在 Keychain Access 檢查精確的 ScreenDock service/identity 項目；本腳本無法確認 Data Protection Keychain 已清除。\n'
if ((ERROR_COUNT > 0)); then
  printf '結果：部分自動清理失敗，並有手動項目待處理（結束碼 3）。\n' >&2
  exit 3
fi
printf '結果：支援的自動清理已完成；仍有 OS/Keychain 手動項目待處理（結束碼 2）。\n'
exit 2
