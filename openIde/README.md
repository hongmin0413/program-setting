# 開啟 IDE 腳本說明

## 檔案結構說明

*   **`openCursor.bat`**：用 Cursor 開啟指定專案資料夾
*   **`openZed.bat`**：用 Zed 開啟指定專案資料夾
*   **`openIde_example.bat`**：範例，兩個 `call` 預設都已註解

---

## 操作流程

### 1. 編輯器更新或安裝位置不同時
*   Cursor：更新 `openCursor.bat` 中的 `cursorExe`。
*   Zed：更新 `openZed.bat` 中的 `zedExe`。

### 2. 有新專案時
*   複製 `openIde_example.bat` 並改名（例如 `alms.bat`）。
*   修改 `workspaceDir` 為專案資料夾路徑。
*   取消想用的編輯器 `call` 的註解（`openCursor.bat`、`openZed.bat`），並刪除不用的 `call`。
*   點擊改名後的 bat。