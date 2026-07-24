# NuISPCmdLineTool

Nuvoton NuMicro ISP 命令列工具 - 從 GUI 版本移植的完整命令列實現

**命令名稱**: `NuISPTool` (簡化版命令名，方便使用)

## 功能特點

✅ **完整的 ISP 功能**
- 更新 APROM 韌體
- 更新 Data Flash
- 更新使用者配置（Config）
- 全片抹除
- 讀取設備 ID
- 讀取韌體版本

✅ **多介面支援**
- USB HID（預設）
- UART 串埠
- SPI / I2C / RS485 / CAN（皆透過 Nu-Link2-Pro 轉接器，同一個 USB HID 裝置，PID 0x3F10）

✅ **協定實現**
- 完整的 ISP 協定棧
- Checksum 校驗
- 包序號管理
- 逾時處理

## 系統要求

- macOS 13.0 或更高版本
- Swift 6.2
- Xcode 命令列工具

## 建置

```bash
cd NuISPCmdLineTool-macOS
swift build
```

**注意**: 可執行命令名稱為 `NuISPTool`

## 使用方法

### 1. 查看幫助

```bash
swift run NuISPTool --help
```

### 2. 列出可用串埠設備

```bash
swift run NuISPTool --list-ports
```

### 3. USB 介面更新 APROM

```bash
# 預設使用 USB 介面
swift run NuISPTool -a firmware.bin

# 明確指定 USB 介面
swift run NuISPTool -o USB -a firmware.bin
```

### 4. UART 介面更新 APROM

```bash
# 先列出可用埠
swift run NuISPTool --list-ports

# 使用指定埠
swift run NuISPTool -o UART /dev/tty.usbserial-xxx -a firmware.bin
```

### 5. 更新 Data Flash

```bash
swift run NuISPTool -o USB -d dataflash.bin
```

### 5a. SPI / I2C / RS485 / CAN 介面更新 APROM

需搭配 Nu-Link2-Pro 轉接器（USB HID，PID 0x3F10）：

```bash
swift run NuISPTool -o SPI -a firmware.bin
swift run NuISPTool -o I2C -a firmware.bin
swift run NuISPTool -o RS485 -a firmware.bin
swift run NuISPTool -o CAN -a firmware.bin
```

> **CAN 介面注意事項**：封包格式與 USB/UART 不同（無 cmd word，4 bytes 為一個分包單位），
> 且沒有 checksum／包序號機制（只要收到回應即視為成功）；更新 Config 僅支援 CONFIG0~3。

### 6. 更新使用者配置

```bash
# 更新單個配置
swift run NuISPTool -o USB -c 0x12345678

# 更新多個配置
swift run NuISPTool -o USB -c 0x12345678 0xABCDEF00
```

### 7. 全片抹除

```bash
swift run NuISPTool -o USB -e
```

### 8. 更新晶片規格數據庫

```bash
NuISPTool --update-db
```

從 Nuvoton 官方 GitHub 下載最新 Flash.py、PartNumID.py、FlashInfo.py，
並更新 `Sources/NuISPTool/Resources/` 內的檔案。

## 命令列參數

| 參數 | 說明 | 範例 |
|------|------|------|
| `-o` | 指定通訊介面（USB/UART/SPI/I2C/RS485/CAN） | `-o USB` 或 `-o UART /dev/tty.xxx` 或 `-o CAN` |
| `-a` | 更新 APROM 韌體 | `-a firmware.bin` |
| `-d` | 更新 Data Flash | `-d dataflash.bin` |
| `-c` | 更新配置（支援多個） | `-c 0x12345678 0xABCDEF00` |
| `-e` | 全片抹除 | `-e` |
| `--list-ports` | 列出可用串埠 | `--list-ports` |
| `--update-db` | 更新晶片規格數據庫 | `--update-db` |
| `--verbose` | 詳細模式：印出每個封包的 USB 收發 hex 內容（預設關閉） | `--verbose` |
| `-h, --help` | 顯示幫助資訊 | `--help` |

## 工作流程

1. **連接設備**
   - USB: 自動搜尋 Nuvoton 設備 (VID: 0x0416)
   - UART: 使用指定的串埠路徑
   - SPI/I2C/RS485/CAN: 透過 Nu-Link2-Pro 轉接器（同一顆 USB HID 裝置，PID 0x3F10）

2. **建立連接**
   - 發送 CONNECT 命令
   - 讀取設備 ID
   - 驗證通訊

3. **執行操作**
   - 更新韌體/配置
   - 驗證 Checksum
   - 顯示進度

4. **完成操作**
   - 執行 APROM（如果更新了韌體）
   - 中斷連接

## 專案結構

```
NuISPCmdLineTool/          # 專案根目錄
├── Package.swift               # Swift Package 配置
├── README.md                   # 專案說明文件
└── Sources/
    └── NuISPTool/              # 原始碼目錄（對應可執行檔案名）
        ├── NuISPTool.swift     # 主程式入口
        ├── Extensions.swift    # 資料型態擴充
        ├── ISPCommands.swift   # ISP 命令定義
        ├── ISPManager.swift    # ISP 核心管理器
        ├── USBDevice.swift     # USB HID 設備通訊
        ├── SerialDevice.swift  # UART 串埠通訊
```
```
├── Resources/              # 晶片規格文件（--update-db 自動更新）
│   ├── Flash.py            # Flash_NuMicro 陣列（AP/DF 大小、位址）
│   ├── PartNumID.py        # PartNumIDs 陣列（PDID 對應晶片名稱）
│   └── FlashInfo.py        # 查詢邏輯說明（參考用）
```

## 晶片規格數據庫

本工具不內建晶片規格，改從 Nuvoton 官方 GitHub 動態取得：

**資料來源**
> https://github.com/OpenNuvoton/ISPTool_Cross_Platform

**運作方式**
1. 首次執行時自動從 GitHub 下載三個 Python 規格文件
2. 檔案儲存於 `Sources/NuISPTool/Resources/`，並 bundle 進可執行檔
3. 執行時從 Bundle Resources 解析，支援 695 個以上晶片型號

**更新方式**
```bash
NuISPTool --update-db
```
- 下載最新 Flash.py / PartNumID.py / FlashInfo.py
- 同時更新 Bundle Resources（立即生效）與 `Sources/NuISPTool/Resources/`（下次 build 時打包）
- 若 Nuvoton 發布新型號，執行此指令即可，**無需修改程式碼**

**無網路時的備用機制**

`Sources/NuISPTool/Resources/` 內的規格文件在 build 時即已 bundle 進可執行檔，因此即使從未執行 `--update-db`，工具仍內含完整的晶片資料庫（695+ 型號）。`--update-db` 僅在需要取得比目前 build 更新的資料時才需執行。

## 技術細節

### ISP 協定

- **資料包格式**: 固定 64 位元組
- **結構**: 
  - 命令 (4 位元組)
  - 包序號 (4 位元組)
  - 資料 (56 位元組)
- **校驗**: 所有位元組求和
- **逾時**: 8 秒

### 支援的命令

```swift
CMD_CONNECT         = 0xAE  // 連接設備
CMD_UPDATE_APROM    = 0xA0  // 更新 APROM
CMD_UPDATE_CONFIG   = 0xA1  // 更新配置
CMD_READ_CONFIG     = 0xA2  // 讀取配置
CMD_ERASE_ALL       = 0xA3  // 全片抹除
CMD_GET_DEVICEID    = 0xB1  // 獲取設備 ID
CMD_UPDATE_DATAFLASH= 0xC3  // 更新 Data Flash
CMD_RUN_APROM       = 0xAB  // 執行 APROM
CMD_RESEND_PACKET   = 0xFF  // 請求裝置重送/確認連線存活（校驗失敗時觸發）
```

### 校驗失敗重試/重送機制（CMD_RESEND_PACKET）

每包資料送出後會驗證回應的 checksum 與包序號，若不符：
1. 先送出 `CMD_RESEND_PACKET`（只校驗 checksum，不校驗包序號，因連線可能已不同步），確認裝置仍在線
2. 確認成功後重新送出同一筆資料（最多重試 10 次，對應 C++ 版 `uRetry = 10`）
3. 若 `CMD_RESEND_PACKET` 也失敗，表示連線已中斷，立即判定燒錄失敗

### 開關印刷（`--verbose`）

預設情況下，燒錄過程只印出必要狀態訊息，**不會**印出每個封包的完整 hex 內容。
燒錄大檔案時每包都印出 hex dump（`--verbose` 開啟時）會產生數千至數萬次終端機輸出，
實測對總燒錄時間有可觀察的影響，因此預設關閉此逐包印刷，只有加上 `--verbose` 才會開啟，
方便除錯時查看每包實際收發內容。程式內對應開關為 `ISPLogConfig.verboseHex`（`USBDevice.swift`）。



## 與 GUI 版本的對比

| 特性 | GUI 版本 | 命令列版本 |
|------|----------|-----------|
| 平台 | macOS (Cocoa) | macOS (Terminal) |
| 相依 | CocoaPods, ORSSerialPort | Swift Package Manager |
| USB 支援 | ✅ | ✅ |
| UART 支援 | ✅ | ✅ |
| SPI/I2C/RS485/CAN 支援 | ✅（需 Nu-Link2-Pro） | ✅（需 Nu-Link2-Pro） |
| 配置檔案 | JSON + UI | 命令列參數 |
| 批次處理 | ❌ | ✅（可腳本化） |
| 自動化 | ❌ | ✅（CI/CD 友好） |

## 故障排除

### USB 設備未找到
```bash
# 檢查設備是否連接
system_profiler SPUSBDataType | grep Nuvoton

# 確認設備處於 ISP 模式（LDROM）
```

### UART 連接失敗
```bash
# 列出所有串埠
swift run NuISPTool --list-ports

# 檢查串埠權限
ls -l /dev/tty.*

# 確認波特率（115200）
```

### 校驗失敗
- 確認設備處於 ISP 模式
- 重新連接設備
- 檢查韌體檔案完整性

## 開發注意事項

### Swift 6.2 並發安全

本專案完全相容 Swift 6.2 的嚴格並發檢查：
- 使用 `@unchecked Sendable` 標記單例
- 使用 `NSLock` 保護共享狀態
- 避免在閉包中直接修改捕獲變數

### 移植自 GUI 版本
> https://github.com/OpenNuvoton/NuISPTool-macOS

保留了核心功能，移除了：
- Cocoa/AppKit 相依
- NotificationCenter 事件
- GUI 相關的狀態管理




