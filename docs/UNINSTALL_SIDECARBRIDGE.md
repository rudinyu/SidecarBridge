# 原始 SidecarBridge macOS Host 與 Viewer 卸載

`../scripts/uninstall-sidecarbridge.sh` 只處理原始 SidecarBridge macOS app bundle，以及明確列出的目前使用者狀態。Host 身分為 `io.sidecarbridge.mac`／**SidecarBridge**；獨立 macOS Viewer 身分為 `io.sidecarbridge.viewer.mac`／**SidecarBridge Viewer**。工具會同時核對 `CFBundlePackageType=APPL`、`CFBundleSupportedPlatforms.0=MacOSX`、bundle ID、`CFBundleDisplayName` 或 `CFBundleName`，以及經 release artifacts 確認的精確 executable 名稱 `SidecarBridge`／`SidecarBridge Viewer`。

這份指南只涵蓋 Mac 上安裝的 `.app`。iPad 也使用 Host 的 bundle ID 與顯示名稱，但其平台不是 `MacOSX`，且不符合 macOS app bundle 驗證；iPad 裝置上的 app 與 sandbox 資料不在此工具可見或可刪除的範圍，工具不會連接或操作 iPad。

## 移除前

1. 在 SidecarBridge Host 的設定中關閉 **Automatic startup**，再到 **System Settings → General → Login Items & Extensions** 檢查 Host 是否仍列為登入項目。Host 使用 `SMAppService.mainApp` 管理可選的登入註冊；此工具不會解除註冊、重設背景項目狀態或變更登入項目。
2. 在 Host 和 Viewer 中撤銷不再需要的配對，然後手動正常結束兩個 app。此工具不會停止 app，也不會替你關閉仍在執行的 app。
3. **先備份或移出收到的檔案。** Host 與 Viewer 使用不同 sandbox container：Host 的 Transfers 位於 `~/Library/Containers/io.sidecarbridge.mac/Data/Library/Application Support/SidecarBridge/Transfers`；原始 Viewer 的收到檔案位於 `~/Library/Containers/io.sidecarbridge.viewer.mac/Data/Library/Application Support/SidecarBridge/SidecarBridge Transfers`。`--remove` 會刪除這兩個精確 container，連同其中所有檔案與 app 支援資料。
4. 重要：配對與裝置身分使用 Keychain service `io.sidecarbridge.trusted-devices`。帳號可能包括 `mac.identity`、`mac.viewer.identity` 和 `pad.mac.*`。此 service 完整保留；不要用 Keychain Access、`security` 或其他工具刪除整個廣泛 service。若要撤銷已儲存配對，請先在 app 內執行 Forget／撤銷配對。

全域 `~/Library/Application Support/SidecarBridge` 位於這些 app-specific containers 之外，工具會保留整個資料夾。工具也不會連接或刪除 iPad 裝置資料。

## 使用方式

先從 repository 根目錄預覽：

```sh
./scripts/uninstall-sidecarbridge.sh
```

工具只會直接檢查 `/Applications` 和 `~/Applications` 中的 `.app` 子項。其他 Applications 目錄可用完整絕對路徑明確指定；每個路徑都會單獨驗證：

```sh
./scripts/uninstall-sidecarbridge.sh --app "/Volumes/Work/Applications/SidecarBridge Viewer.app"
```

確認列出的路徑是要移除的原始 macOS app，先手動關閉 Host 和 Viewer，再執行：

```sh
./scripts/uninstall-sidecarbridge.sh --remove
```

執行時必須在互動終端輸入 `REMOVE`。不要使用 `sudo`；需要系統管理員權限的 `/Applications` 項目請在 Finder 中單獨處理。若路徑含符號連結、路徑跳脫，位於來源碼／建置／測試／Downloads 等不安全位置，或 bundle 身分不符，工具會拒絕處理。

## 清理範圍與 macOS 權限

預設模式會列出符合身分的 app bundles、精確的狀態目標和兩個 TCC 重設請求，不會變更任何項目。確認後，`--remove` 只會處理以下目標：

- 身分驗證通過的原始 Host/Viewer `.app` bundles。
- 對 `io.sidecarbridge.mac` 和 `io.sidecarbridge.viewer.mac` 各自精確的 `~/Library/Preferences/<bundle-id>.plist`、直接 `ByHost/<bundle-id>.<UUID>.plist` 檔案（UUID 後綴必須符合標準 8-4-4-4-12 位十六進位格式；其他相似名稱會略過）、`Caches/<bundle-id>`、`Saved Application State/<bundle-id>.savedState`、`Logs/<bundle-id>` 和 `Containers/<bundle-id>`。工具只列出直接 ByHost 子項，不會遞迴搜尋。
- 互動確認後，對上述兩個已核實 macOS bundle ID 執行 `tccutil reset All <bundle-id>`。這會請 macOS 重設該 app ID 支援的逐 app TCC 記錄；不代表所有系統權限狀態都已清除。

Container 內的 app sandbox 檔案可能包含收到的 Transfers、app 支援檔和其他使用者內容，會隨精確 container 永久刪除。請先備份。工具不會刪除全域 `~/Library/Application Support/SidecarBridge`、Keychain 項目、iPad 裝置資料、其他 container／group、來源碼、測試、build 輸出、Downloads、ScreenDock、全域 Codex 或其他資料；不會停止 app、變更登入項目／launchd 狀態或清理防火牆設定。每個目標在預覽和移除前都會檢查路徑及 symlink；若路徑含 symlink、類型不符或無法安全確認，工具會停止或保留該目標。

Host 曾使用 **Screen Recording**、**Accessibility/PostEvent** 和 **Local Network／Bonjour** 權限；Viewer 使用 **Local Network／Bonjour**。部分逐 app TCC 記錄可由 `tccutil reset All <bundle-id>` 重設，但 macOS 沒有受支援的方法可將 Local Network 權限重設回「尚未詢問」；此命令也不會清除 Local Network 權限。移除 app bundle 或重設支援的 per-app TCC 記錄，都不保證所有權限歷史從 macOS 消失。本工具只對上方兩個 bundle ID 請求 `tccutil` 重設，不編輯 TCC 資料庫。Apple 說明 Local Network 權限模型與系統管理方式的文件是 [TN3179：Understanding Local Network Privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。

Host 的可選登入註冊由 `SMAppService.mainApp` 管理；目前沒有識別出專用 LaunchAgent 或 helper。請使用 app 內設定與 System Settings 手動檢查登入項目。移除 app bundle 不會保證 macOS 已記錄的登入項目或權限歷史一併清除。
