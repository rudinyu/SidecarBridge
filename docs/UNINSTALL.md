# ScreenDock Host/Viewer 卸載

`../scripts/uninstall-screendock.sh` 是獨立的 macOS Bash 3.2 卸載工具，只使用 macOS 內建程式。預設只預覽，也可明確加 `--dry-run`；它不需要 Python、Swift、Xcode 或網路，也不會遞迴搜尋來源碼、Downloads 或 `.build`。

## 移除前先做

1. 在 **ScreenDock Host → Settings** 將 **Automatic startup** 關閉。Host 使用 `SMAppService.mainApp` 註冊登入項目；卸載工具沒有可安全代替 app 的外部解除註冊流程。之後也請到 **System Settings → General → Login Items & Extensions** 檢查是否還有 ScreenDock Host 項目。
2. 在 **ScreenDock Host** 和 **ScreenDock Viewer** 各自執行 **Forget All**，撤銷已儲存的配對。這不會刪除穩定身分 Keychain 項目。
3. 先備份或移出收到的檔案，然後正常結束 Host 和 Viewer。清理會永久刪除兩個 app sandbox 中的 `Transfers`，以及列出的 ScreenDock 使用者資料。
4. 若要清除受 Data Protection 保護的 Keychain 項目，先在 **Keychain Access** 檢查 ScreenDock 的精確 service 與 identity 項目。Release services 是 `com.screendock.host.trusted-devices` 和 `com.screendock.viewer.trusted-devices`；Debug services 是 `com.screendock.debug.host.trusted-devices` 和 `com.screendock.debug.viewer.trusted-devices`。Host/Viewer 穩定身分帳號（例如 `mac.identity`、`mac.viewer.identity`）也可能保留。只處理 ScreenDock 項目；不要刪除 `io.sidecarbridge.*` 或其他 app 的 Keychain 項目。`security` 命令列工具只會嘗試處理舊式 file Keychain 項目，不能確認或清除 Data Protection Keychain。

## 使用方式

從 repository 根目錄先預覽：

```sh
./scripts/uninstall-screendock.sh --dry-run
```

若 app 安裝在標準搜尋位置以外，把每個 `.app` 路徑明確加上；`--app` 可重複使用：

```sh
./scripts/uninstall-screendock.sh --app "/Applications/Utilities/ScreenDock Host.app"
```

完成前置步驟並確認預覽範圍後才執行清理；互動模式必須輸入 `REMOVE`：

```sh
./scripts/uninstall-screendock.sh --remove
```

Release Host/Viewer 是預設範圍。只有明確要移除 Debug 安裝及其資料時才加 `--include-debug`：

```sh
./scripts/uninstall-screendock.sh --remove --include-debug
```

`--yes` 只可與 `--remove` 一起用，會略過文字確認，但仍會先印出 Transfers 永久刪除提醒。請以目前登入的非 root 使用者執行，**不要用 sudo 跑整份腳本**。

## 清理範圍

預設只接受 Release bundle ID `com.screendock.host`、`com.screendock.viewer`；`--include-debug` 才接受 `com.screendock.host.debug`、`com.screendock.viewer.debug`。工具只會在 `/Applications`、`~/Applications`、已掛載磁碟的 `/Volumes/*/Applications` 直接子層尋找 `.app`，再以 `plutil` 驗證 bundle ID；也會檢查明確傳入的 `--app`。它不會搜尋其他目錄。符號連結、路徑跳脫、非目前使用者的 HOME、root 執行及身分不符的 bundle 都會拒絕。

在目前使用者的 Library 中，只處理精確的 app ID 偏好、ByHost UUID 偏好、Caches、Saved Application State、Logs、Containers、Application Scripts，以及 `Application Support/ScreenDock`。`--include-debug` 另包含 Debug app ID、`com.screendock.debug.host/viewer` 偏好 suites、ByHost 項目與 `Application Support/ScreenDock Debug`。Sandbox container 內的 Transfers 也會隨 container 移除。除 app bundle 外，不會刪除其他磁碟或其他使用者的資料。

確認後，工具只會向精確 bundle ID 對應的執行中 app 發出 AppKit graceful terminate，最多等待 15 秒；仍在執行或無法檢查時會停止，不刪除資料。接著會逐 app 執行 `tccutil reset All <bundle-id>`，再處理精確偏好 domain、最多 1024 次並確認已無殘留的舊式 Keychain service 項目、資料白名單與已重新驗證身分的 app bundle。受保護的 sandbox container 可能需要 Terminal 的 Full Disk Access；若遭拒，工具會指出路徑並保留該資料，不會繞過權限或自動呼叫 `sudo`。

## 尚須手動處理與結果碼

- macOS 沒有受支援的 Local Network 權限「重設回未詢問」功能。請到 **System Settings → Privacy & Security → Local Network** 撤銷 ScreenDock Host/Viewer 的存取；歷史項目仍可能留在列表中。見 Apple [TN3179：Understanding Local Network Privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。
- `tccutil reset All` 只表示已要求 macOS 重設該 app ID 支援的 per-app TCC 權限。Host 可能涉及 Screen Recording、Accessibility 和 PostEvent；實際項目由 macOS 管理。這不代表 Local Network 或所有系統隱私記錄都已清除。
- Login Item 若仍存在，請在 System Settings 手動移除。工具不會重設全域背景項目資料庫。
- 若你曾自行建立規則，請檢查 **System Settings → Network → Firewall → Options**，以及有使用時的 Little Snitch。ScreenDock 沒有安裝 helper 或 LaunchAgent；工具不會重設全域防火牆，也不會假設存在 app 專屬規則。
- 受 Data Protection 保護的 Keychain 內容無法由這個命令列清理流程確認；請按上方清單在 Keychain Access 檢查精確 ScreenDock 項目。Apple 說明了 [macOS Keychain 的工具與儲存方式](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)。
- `/Applications` 權限不足時，工具會指出未刪除的 bundle 路徑。請在 Finder 以管理員授權手動移除該 app；不要因此用 `sudo` 重跑整份腳本。

`--help` 和 dry-run 成功時回傳 `0`；`--remove` 在可自動處理項目完成後，仍有上述手動事項時回傳 `2`；發生自動清理錯誤且另有手動事項時回傳 `3`。若 AppKit 無法查詢/停止 app，或 app 在等待後仍執行，會在刪除前中止並回傳非零狀態。請以終端摘要和實際路徑判斷哪些動作完成；非零碼不會被描述成完整卸載。
