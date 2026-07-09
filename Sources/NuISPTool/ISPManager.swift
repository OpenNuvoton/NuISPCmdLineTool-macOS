//
//  ISPManager.swift
//  NuISPCmdLineTool-ASUS
//
//  移植自 GUI 版本的 ISPManager.swift
//  简化为命令行版本，移除 GUI 依赖
//

import Foundation

/// 晶片信息結構體
struct ChipInfo {
    let deviceID: UInt
    let name: String
    let apromeSize: UInt
    let dataFlashSize: UInt  // 若為 0 表示無 Data Flash
    let dataFlashAddr: UInt
}

// MARK: - 晶片數據庫
//
// 資料來源：官方 Nuvoton ISPTool_Cross_Platform GitHub 倉庫
//   https://github.com/OpenNuvoton/ISPTool_Cross_Platform
//
// 使用以下三個 Python 規格文件建立晶片數據庫：
//   Flash.py     → Flash_NuMicro 陣列（AP/DF 大小、DF 位址、PDID）
//   PartNumID.py → PartNumIDs 陣列（PDID 對應晶片名稱）
//   FlashInfo.py → 參考用（邏輯說明）
//
// 【晶片型號更新方式】
//   本工具不內建晶片規格，首次執行時自動從 GitHub 下載並快取於本機。
//   若 Nuvoton 發布新型號，執行以下指令更新（需網路連線）：
//
//     NuISPTool --update-db
//
//   資料將自動儲存至：
//     ~/Library/Application Support/NuISPTool/Flash.py
//     ~/Library/Application Support/NuISPTool/PartNumID.py
//     ~/Library/Application Support/NuISPTool/FlashInfo.py

// 官方 Python 規格文件的 GitHub raw 下載網址
private let FLASH_PY_URL     = "https://raw.githubusercontent.com/OpenNuvoton/ISPTool_Cross_Platform/master/ISP_Command_Line_Tool_SampleCode/Flash.py"
private let PARTNUM_PY_URL   = "https://raw.githubusercontent.com/OpenNuvoton/ISPTool_Cross_Platform/master/ISP_Command_Line_Tool_SampleCode/PartNumID.py"
private let FLASHINFO_PY_URL = "https://raw.githubusercontent.com/OpenNuvoton/ISPTool_Cross_Platform/master/ISP_Command_Line_Tool_SampleCode/FlashInfo.py"

// 執行時期 Python 規格文件目錄（Bundle.module 對應 Sources/NuISPTool/Resources/）
private var pyResourceDir: String {
    Bundle.module.resourcePath ?? Bundle.main.bundlePath
}

// 計算算術運算式（如 "1024 * 1024" 或 "32 * 1024" 或 "512"）
private func evalArith(_ s: String) -> UInt? {
    let parts = s.components(separatedBy: "*").map { $0.trimmingCharacters(in: .whitespaces) }
    if parts.count == 1 { return UInt(parts[0]) }
    if parts.count == 2, let a = UInt(parts[0]), let b = UInt(parts[1]) { return a * b }
    return nil
}

/// 解析 Flash.py 中的 Flash_NuMicro 陣列
/// 格式：[AP_size, DF_size, RAM_size, DF_address, LD_size, PDID]  #ChipName
private func parseFlashPy(_ content: String) -> [UInt: (apSize: UInt, dfSize: UInt, dfAddr: UInt)] {
    var result: [UInt: (apSize: UInt, dfSize: UInt, dfAddr: UInt)] = [:]

    // 找到 Flash_NuMicro 區段
    guard let startRange = content.range(of: "Flash_NuMicro = [") else { return result }
    let section = String(content[startRange.upperBound...])

    // 匹配每一行：[數字或算式, 數字或算式, 數字或算式, 0xHEX, 數字或算式, 0xHEX]
    let pattern = #"\[\s*([\d\s*]+),\s*([\d\s*]+),\s*([\d\s*]+),\s*(0x[0-9A-Fa-f]+),\s*([\d\s*]+),\s*(0x[0-9A-Fa-f]+)\s*\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }

    let nsSection = section as NSString
    let matches = regex.matches(in: section, range: NSRange(section.startIndex..., in: section))
    for m in matches {
        guard m.numberOfRanges == 7 else { continue }
        let apStr   = nsSection.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let dfStr   = nsSection.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        let dfAStr  = nsSection.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
        let pdidStr = nsSection.substring(with: m.range(at: 6)).trimmingCharacters(in: .whitespaces)
        guard let apSize = evalArith(apStr),
              let dfSize = evalArith(dfStr),
              let dfAddr = UInt(dfAStr.dropFirst(2), radix: 16),
              let pdid   = UInt(pdidStr.dropFirst(2), radix: 16) else { continue }
        result[pdid] = (apSize: apSize, dfSize: dfSize, dfAddr: dfAddr)
    }
    return result
}

/// 解析 PartNumID.py 中的 PartNumIDs 陣列
/// 格式：["ChipName", 0xPDID, PROJ_TYPE],
private func parsePartNumPy(_ content: String) -> [UInt: String] {
    var result: [UInt: String] = [:]
    let pattern = #"\["([^"]+)"\s*,\s*(0x[0-9A-Fa-f]+)\s*,"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
    let ns = content as NSString
    let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
    for m in matches {
        guard m.numberOfRanges == 3 else { continue }
        let name    = ns.substring(with: m.range(at: 1))
        let pdidStr = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        guard let pdid = UInt(pdidStr.dropFirst(2), radix: 16) else { continue }
        result[pdid] = name
    }
    return result
}

/// 合併 Flash.py 和 PartNumID.py 資料，建構 ChipInfo 字典
private func buildChipDatabase(flashContent: String, partNumContent: String) -> [UInt: ChipInfo] {
    let flashData   = parseFlashPy(flashContent)
    let nameData    = parsePartNumPy(partNumContent)
    var database: [UInt: ChipInfo] = [:]
    for (pdid, mem) in flashData {
        let name = nameData[pdid] ?? String(format: "0x%08X", pdid)
        database[pdid] = ChipInfo(deviceID: pdid, name: name,
                                  apromeSize: mem.apSize,
                                  dataFlashSize: mem.dfSize,
                                  dataFlashAddr: mem.dfAddr)
    }
    return database
}

/// 從 GitHub 下載三個 Python 規格文件寫入 Bundle Resources，回傳解析結果
private func downloadAndCachePyFiles() -> [UInt: ChipInfo]? {
    let files: [(url: String, name: String)] = [
        (FLASH_PY_URL,     "Flash.py"),
        (PARTNUM_PY_URL,   "PartNumID.py"),
        (FLASHINFO_PY_URL, "FlashInfo.py"),
    ]

    // 寫入目錄1：Bundle Resources（立即生效）
    let bundleDir = pyResourceDir
    // 寫入目錄2：Sources/NuISPTool/Resources/（跨 build 持久保留）
    let cwd = FileManager.default.currentDirectoryPath
    let sourceDir = cwd + "/Sources/NuISPTool/Resources"
    let hasSourceDir = FileManager.default.fileExists(atPath: sourceDir)

    for file in files {
        fputs("   ⬇️  下載 \(file.name)...\n", stderr)
        guard let url  = URL(string: file.url),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            fputs("   ❌ 下載失敗: \(file.url)\n", stderr)
            return nil
        }
        try? data.write(to: URL(fileURLWithPath: bundleDir + "/" + file.name))
        if hasSourceDir {
            try? data.write(to: URL(fileURLWithPath: sourceDir + "/" + file.name))
        }
    }
    if hasSourceDir {
        fputs("   📁 已同步更新 Sources/NuISPTool/Resources/\n", stderr)
    }
    return loadDbFromResources()
}

/// 從 Bundle Resources 讀取 Python 文件並建構數據庫
private func loadDbFromResources() -> [UInt: ChipInfo]? {
    let resDir = pyResourceDir
    guard let flashContent   = try? String(contentsOfFile: resDir + "/Flash.py",     encoding: .utf8),
          let partNumContent = try? String(contentsOfFile: resDir + "/PartNumID.py", encoding: .utf8),
          !flashContent.isEmpty, !partNumContent.isEmpty else { return nil }
    let db = buildChipDatabase(flashContent: flashContent, partNumContent: partNumContent)
    return db.isEmpty ? nil : db
}

/// 初始化時加載晶片數據庫（Bundle Resources → 自動下載 → 最小備用）
func loadChipDatabase() -> [UInt: ChipInfo] {
    // 1. 優先從 Bundle Resources 讀取（Sources/NuISPTool/Resources/）
    if let db = loadDbFromResources() {
        fputs("✅ 已加載 \(db.count) 個晶片規格（來自 Resources）\n", stderr)
        return db
    }

    // 2. Resources 內無資料（首次執行），自動從 GitHub 下載
    fputs("ℹ️  首次執行：自動從 GitHub 下載晶片規格文件...\n", stderr)
    if let db = downloadAndCachePyFiles() {
        fputs("✅ 已加載 \(db.count) 個晶片規格（已儲存快取）\n", stderr)
        return db
    }

    // 3. 無網路時的最小備用數據庫
    fputs("⚠️  無法連線 GitHub，使用內建最小數據庫\n", stderr)
    fputs("   如需完整支援，請連線網路後執行：NuISPTool --update-db\n", stderr)
    return [
        0x01B46760: ChipInfo(deviceID: 0x01B46760, name: "M467HJHAE",
                             apromeSize: 0x100000, dataFlashSize: 0x0, dataFlashAddr: 0x0),
        0xFFFFFFFF: ChipInfo(deviceID: 0xFFFFFFFF, name: "Unknown Chip",
                             apromeSize: 0x20000, dataFlashSize: 0x2000, dataFlashAddr: 0x1E000),
    ]
}

/// ISP 操作結果
struct ISPResult {
    let success: Bool
    let data: Data?
    let message: String
    let isTimeout: Bool
    
    static func success(data: Data? = nil, message: String = "操作成功") -> ISPResult {
        return ISPResult(success: true, data: data, message: message, isTimeout: false)
    }
    
    static func failure(message: String, timeout: Bool = false) -> ISPResult {
        return ISPResult(success: false, data: nil, message: message, isTimeout: timeout)
    }
}

/// ISP 管理器 - 核心功能类
class ISPManager: @unchecked Sendable {
    // 单例
    static let shared = ISPManager()
    
    // 设备连接
    private var usbDevice: USBDevice?
    private var serialDevice: SerialDevice?
    
    // 設備信息
    private var currentChip: ChipInfo?
    private var deviceIDValue: UInt = 0xFFFFFFFF
    
    // 晶片數據庫（動態加載）
    private var chipDatabase: [UInt: ChipInfo] = [:]
    
    // 配置
    private var interfaceType: NulinkInterfaceType = .usb
    private var packetNumber: UInt = 0x00000001
    private let timeout: TimeInterval = 8.0
    
    private init() {
        // 初始化時加載晶片數據庫（快取或自動下載）
        self.chipDatabase = loadChipDatabase()
    }
    
    /// 強制從 GitHub 更新晶片數據庫（供 --update-db 使用）
    func updateDB() -> Bool {
        fputs("🔄 正在從官方 ISPTool_Cross_Platform 下載晶片規格文件...\n", stderr)
        fputs("   https://github.com/OpenNuvoton/ISPTool_Cross_Platform\n", stderr)
        if let db = downloadAndCachePyFiles(), !db.isEmpty {
            self.chipDatabase = db
            fputs("✅ 更新完成，共 \(db.count) 個晶片規格\n", stderr)
            fputs("   儲存路徑：\(pyResourceDir)/\n", stderr)
            return true
        } else {
            fputs("❌ 下載失敗，請確認網路連線\n", stderr)
            return false
        }
    }
    
    // MARK: - 连接管理
    
    /// 使用 USB 連接設備
    /// - Returns: 是否成功連接
    func connectUSB() -> Bool {
        print("\n🔍 正在搜尋 USB 設備...")
        
        guard let deviceInfo = USBDeviceManager.shared.findNuvotonDevice() else {
            return false
        }
        
        usbDevice = USBDevice(deviceInfo)
        interfaceType = .usb
        
        print("✅ USB 設備已連接\n")
        return true
    }
    
    /// 使用 UART 連接設備
    /// - Parameter portPath: 串埠路徑
    /// - Returns: 是否成功連接
    func connectUART(portPath: String) -> Bool {
        print("\n📡 正在打開串埠...")
        
        let serial = SerialDevice()
        guard serial.open(portPath: portPath) else {
            return false
        }
        
        serialDevice = serial
        interfaceType = .uart
        
        print("✅ 串埠設備已連接\n")
        return true
    }
    
    /// 断开连接
    func disconnect() {
        usbDevice?.close()
        usbDevice = nil
        serialDevice?.close()
        serialDevice = nil
        USBDeviceManager.shared.close()
    }
    
    // MARK: - ISP 命令
    
    /// 發送連接命令
    /// - Returns: 操作結果
    func sendConnect() -> ISPResult {
        print("📡 發送連接命令...")
        
        packetNumber = 0x00000001
        let cmd = ISPCommands.CMD_CONNECT
        let sendBuffer = ISPCommandTool.toCMD(cmd: cmd, packetNumber: packetNumber)
        
        guard let readBuffer = sendCommand(sendBuffer) else {
            return .failure(message: "連接逾時", timeout: true)
        }
        
        guard validateResponse(sendBuffer: sendBuffer, readBuffer: readBuffer) else {
            return .failure(message: "校驗失敗")
        }
        
        print("✅ 設備連接成功")
        return .success(data: Data(readBuffer), message: "連接成功")
    }
    
    /// 獲取設備 ID
    /// - Returns: 操作結果（data 中包含設備 ID）
    func getDeviceID() -> ISPResult {
        print("🔍 讀取設備 ID...")
        
        let cmd = ISPCommands.CMD_GET_DEVICEID
        let sendBuffer = ISPCommandTool.toCMD(cmd: cmd, packetNumber: packetNumber)
        
        guard let readBuffer = sendCommand(sendBuffer) else {
            return .failure(message: "讀取設備 ID 逾時", timeout: true)
        }
        
        guard validateResponse(sendBuffer: sendBuffer, readBuffer: readBuffer) else {
            return .failure(message: "校驗失敗")
        }
        
        let deviceIDStr = ISPCommandTool.toDeviceID(readBuffer: readBuffer)
        // 轉換為 UInt
        if let deviceID = UInt(deviceIDStr, radix: 16) {
            self.deviceIDValue = deviceID
            // 查詢晶片信息
            if let chipInfo = self.chipDatabase[deviceID] {
                self.currentChip = chipInfo
                print("✅ 設備 ID: 0x\(deviceIDStr)")
                print("📱 晶片型號: \(chipInfo.name)")
                print("💾 APROM 大小: \(chipInfo.apromeSize / 1024)KB")
                if chipInfo.dataFlashSize > 0 {
                    print("💾 Data Flash 大小: \(chipInfo.dataFlashSize / 1024)KB")
                } else {
                    print("⚠️  該晶片不支援 Data Flash")
                }
            } else {
                self.currentChip = self.chipDatabase[0xFFFFFFFF]  // 使用預設值
                print("✅ 設備 ID: 0x\(deviceIDStr) (未知型號，使用預設配置)")
            }
        }
        
        return .success(data: Data(readBuffer), message: "設備 ID: 0x\(deviceIDStr)")
    }
    
    /// 讀取配置
    /// - Returns: 操作結果
    func readConfig() -> ISPResult {
        print("📖 讀取設備配置...")
        
        let cmd = ISPCommands.CMD_READ_CONFIG
        let sendBuffer = ISPCommandTool.toCMD(cmd: cmd, packetNumber: packetNumber)
        
        guard let readBuffer = sendCommand(sendBuffer) else {
            return .failure(message: "讀取配置逾時", timeout: true)
        }
        
        guard validateResponse(sendBuffer: sendBuffer, readBuffer: readBuffer) else {
            return .failure(message: "校驗失敗")
        }
        
        print("✅ 配置讀取成功")
        return .success(data: Data(readBuffer), message: "配置讀取成功")
    }
    
    /// 更新配置（先讀取現有值，只覆蓋指定位置，避免清除 CONFIG1/2/3）
    /// - Parameter configs: 配置值陣列（index 0 = CONFIG0, 1 = CONFIG1, ...）
    /// - Returns: 操作結果
    func updateConfig(configs: [UInt]) -> ISPResult {
        // 1. 先讀取裝置目前所有 config 值（與 GUI 版本相同流程）
        let readResult = readConfig()
        guard readResult.success, let rawData = readResult.data else {
            return .failure(message: "讀取現有配置失敗，無法安全寫入")
        }

        // 2. 從回應 bytes[8..55] 解析 12 個 config UInt（Little-Endian）
        let rawBytes = [UInt8](rawData)
        var currentConfigs: [UInt] = []
        for i in 0..<12 {
            let offset = 8 + i * 4
            guard offset + 3 < rawBytes.count else { break }
            let val = UInt(rawBytes[offset])
                    | (UInt(rawBytes[offset + 1]) << 8)
                    | (UInt(rawBytes[offset + 2]) << 16)
                    | (UInt(rawBytes[offset + 3]) << 24)
            currentConfigs.append(val)
        }

        // 3. 只更新使用者指定的位置，其餘保持原值
        for (index, value) in configs.enumerated() where index < currentConfigs.count {
            currentConfigs[index] = value
        }

        print("⚙️  更新設備配置...")
        for (i, v) in currentConfigs.prefix(4).enumerated() {
            let changed = i < configs.count ? " ← 已修改" : ""
            print("   CONFIG\(i): 0x\(String(format: "%08X", v))\(changed)")
        }

        // 4. 將所有 config 值一次寫回（與 GUI 版本相同）
        let sendBuffer = ISPCommandTool.toUpdateConfigCMD(configs: currentConfigs, packetNumber: packetNumber)

        guard let readBuffer = sendCommand(sendBuffer) else {
            return .failure(message: "更新配置逾時", timeout: true)
        }

        guard validateResponse(sendBuffer: sendBuffer, readBuffer: readBuffer) else {
            return .failure(message: "校驗失敗")
        }

        print("✅ 配置更新成功")
        return .success(message: "配置更新成功")
    }
    
    /// 抹除全部
    /// - Returns: 操作結果
    func eraseAll() -> ISPResult {
        print("🧹 執行全片抹除...")
        
        let cmd = ISPCommands.CMD_ERASE_ALL
        let sendBuffer = ISPCommandTool.toCMD(cmd: cmd, packetNumber: packetNumber)
        
        guard let readBuffer = sendCommand(sendBuffer) else {
            return .failure(message: "抹除操作逾時", timeout: true)
        }
        
        guard validateResponse(sendBuffer: sendBuffer, readBuffer: readBuffer) else {
            return .failure(message: "校驗失敗")
        }
        
        print("✅ 全片抹除完成")
        return .success(message: "抹除完成")
    }
    
    /// 更新 APROM
    /// - Parameters:
    ///   - filePath: BIN 文件路径
    ///   - startAddress: 起始地址（默认 0x0）
    /// - Returns: 操作结果
    func updateAPROM(filePath: String, startAddress: UInt = 0x0) -> ISPResult {
        return updateBinary(filePath: filePath, cmd: .CMD_UPDATE_APROM, startAddress: startAddress, name: "APROM")
    }
    
    /// 更新 Data Flash
    /// - Parameters:
    ///   - filePath: BIN 文件路径
    ///   - startAddress: 起始地址
    /// - Returns: 操作结果
    func updateDataFlash(filePath: String, startAddress: UInt) -> ISPResult {
        // 檢查晶片是否支援 Data Flash
        if let chip = currentChip, chip.dataFlashSize == 0 {
            return .failure(message: "該晶片型號 (\(chip.name)) 不支援 Data Flash，無法燒錄")
        }
        
        return updateBinary(filePath: filePath, cmd: .CMD_UPDATE_DATAFLASH, startAddress: startAddress, name: "Data Flash")
    }
    
    /// 运行 APROM
    /// - Returns: 操作结果
    func runAPROM() -> ISPResult {
        print("🚀 送出 RUN_APROM 命令...")
        
        let cmd = ISPCommands.CMD_RUN_APROM
        let sendBuffer = ISPCommandTool.toCMD(cmd: cmd, packetNumber: packetNumber)
        
        // 送出命令後設備立即跳轉到 APROM，USB 斷線屬於正常現象，不視為錯誤
        _ = sendCommand(sendBuffer)
        
        print("✅ 設備已重啟進入 APROM")
        return .success(message: "設備已重啟")
    }
    
    // MARK: - 内部方法
    
    /// 更新二進位檔案（通用方法）
    private func updateBinary(filePath: String, cmd: ISPCommands, startAddress: UInt, name: String) -> ISPResult {
        print("🚀 開始更新 \(name)...")
        print("   檔案: \(filePath)")
        print("   起始位址: 0x\(String(format: "%08X", startAddress))")
        
        // 讀取檔案
        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return .failure(message: "無法讀取檔案: \(filePath)")
        }
        
        let fileSize = fileData.count
        print("   檔案大小: \(fileSize) 位元組")
        
        // 第一包 header = cmd(4)+packetNo(4)+address(4)+size(4) = 16 bytes，資料最多 48 bytes
        // 後續包 header = cmd(4)+packetNo(4) = 8 bytes，資料最多 56 bytes
        let firstChunkSize = 48
        let remainChunkSize = 56
        let totalPackets = 1 + max(0, (fileSize - firstChunkSize + remainChunkSize - 1) / remainChunkSize)
        var offset = 0
        var isFirst = true
        var currentPacket = 0
        
        while offset < fileSize {
            let chunkSize = isFirst ? firstChunkSize : remainChunkSize
            let remaining = fileSize - offset
            let dataSize = min(remaining, chunkSize)
            var chunkData = fileData.subdata(in: offset..<(offset + dataSize))
            // 補齊至標準大小（與 GUI 版本一致）
            if chunkData.count < chunkSize {
                chunkData.append(contentsOf: Array(repeating: 0x00, count: chunkSize - chunkData.count))
            }
            
            // 對應 C++ 版 Thread_ProgramFlash() 中的 `unsigned int uRetry = 10;` 重試迴圈。
            // 每個封包最多重試 10 次，每次重試前都會重新組出封包（序號可能已前進）。
            var resendRetry = 10
            var packetAccepted = false
            
            while true {
                let sendBuffer = ISPCommandTool.toUpdateBinCMD(
                    cmd: cmd,
                    packetNumber: packetNumber,
                    startAddress: startAddress,
                    size: fileSize,
                    data: chunkData,
                    isFirst: isFirst
                )
                
                guard let readBuffer = sendCommand(sendBuffer) else {
                    return .failure(message: "更新 \(name) 逾時（包 \(currentPacket + 1)/\(totalPackets)）", timeout: true)
                }
                
                if validateResponse(sendBuffer: sendBuffer, readBuffer: readBuffer) {
                    packetAccepted = true
                    break
                }
                
                // 扇區邊界雙重回應處理：
                // MCU 在 4KB 扇區邊界抹除時會先送出中間回應（校驗和不符），
                // 抹除完成後才送出正確回應。清除舊緩衝並等待第二個回應。
                print("⚠️  校驗失敗，等待 MCU 扇區抹除完成後重試讀取...")
                if let retryBuffer = readNextUSBResponse(timeout: 1.5),
                   validateResponse(sendBuffer: sendBuffer, readBuffer: retryBuffer) {
                    print("✅ 重試讀取成功（扇區邊界中間回應已跳過）")
                    packetAccepted = true
                    break
                }
                
                // 校驗仍然失敗，對應 C++ 版 `m_ISPLdDev.bResendFlag` 為真的分支：
                // 送出 CMD_RESEND_PACKET 確認連線是否仍存活（對應 CMD_Resend()），
                // 成功才重送本封包；重試次數用盡、或為第一包（對應 i == 0）、
                // 或 CMD_RESEND_PACKET 本身失敗，都直接判定燒錄失敗。
                resendRetry -= 1
                // 對應 C++ 版 WriteFile 成功即遞增 m_uCmdIndex：
                // 無論回應內容是否正確，封包本身已送達，序號需前進一輪。
                packetNumber += 2
                
                if resendRetry <= 0 || isFirst || !sendResendPacket() {
                    return .failure(message: "校驗失敗（包 \(currentPacket + 1)/\(totalPackets)）")
                }
                
                print("🔄 已送出 CMD_RESEND_PACKET，重送封包（剩餘重試次數 \(resendRetry)）...")
            }
            
            if !packetAccepted {
                return .failure(message: "校驗失敗（包 \(currentPacket + 1)/\(totalPackets)）")
            }
            
            offset += dataSize
            isFirst = false
            currentPacket += 1
            
            // 顯示進度
            let progress = (currentPacket * 100) / totalPackets
            print("   進度: \(progress)% (\(currentPacket)/\(totalPackets) 包)")
        }
        
        print("✅ \(name) 更新完成")
        return .success(message: "\(name) 更新完成")
    }
    
    /// 在校驗失敗後嘗試讀取下一個回應（用於 4KB 扇區邊界的雙重回應情況）
    ///
    /// Nuvoton M467/M460 ISP bootloader 在封包橫跨 4KB 扇區邊界時會先送出一個
    /// 中間回應（校驗和不符），等待扇區抹除完成後再送出正確回應。
    /// 此方法同步清除舊回應，並等待正確的第二個回應。
    private func readNextUSBResponse(timeout: TimeInterval = 1.0) -> [UInt8]? {
        guard let usb = usbDevice else { return nil }
        usb.clearBufferSync()   // 同步清除中間回應
        let data = usb.read(timeout: timeout)
        return data?.toUint8Array
    }
    
    /// 送出 CMD_RESEND_PACKET，請求裝置重新傳送前一個遺失/毀損的回應封包
    ///
    /// 對應 C++ 版 `ISPLdCMD::CMD_Resend()`：
    /// 用於校驗連續失敗時，先確認連線是否仍然存活（裝置仍能正確回應），
    /// 成功的話再由呼叫端重送目前的資料封包；若連 CMD_RESEND_PACKET 都失敗，
    /// 表示連線已經中斷，應立即判定燒錄失敗。
    private func sendResendPacket() -> Bool {
        let sendBuffer = ISPCommandTool.toCMD(cmd: .CMD_RESEND_PACKET, packetNumber: packetNumber)
        
        guard let readBuffer = sendCommand(sendBuffer) else {
            print("❌ CMD_RESEND_PACKET 逾時")
            return false
        }
        
        // 對應 C++ 版 ReadFile(..., bCheckIndex = FALSE)：
        // 連線可能已不同步，因此只驗證校驗和，不驗證封包序號。
        let checksum = ISPCommandTool.toChecksumBySendBuffer(sendBuffer: sendBuffer)
        let resultChecksum = ISPCommandTool.toChecksumByReadBuffer(readBuffer: readBuffer)
        
        guard checksum == resultChecksum else {
            print("❌ CMD_RESEND_PACKET 校驗失敗")
            return false
        }
        
        // 對應 C++ 版 WriteFile 成功即遞增 m_uCmdIndex：封包已送達，序號前進一輪。
        packetNumber += 2
        return true
    }

    /// 發送命令並接收響應
    private func sendCommand(_ sendBuffer: [UInt8]) -> [UInt8]? {
        if interfaceType == .uart {
            // UART 模式
            guard let serial = serialDevice else {
                print("❌ 串埠未初始化")
                return nil
            }
            
            let data = serial.writeAndRead(data: Data(sendBuffer))
            return data?.toUint8Array
        } else {
            // USB 模式
            guard let usb = usbDevice else {
                print("❌ USB 設備未初始化")
                return nil
            }
            
            usb.write(sendBuffer, interfaceType: interfaceType)
            let data = usb.read(timeout: timeout)
            return data?.toUint8Array
        }
    }
    
    /// 驗證響應（校驗和 + 包序號）
    private func validateResponse(sendBuffer: [UInt8], readBuffer: [UInt8]) -> Bool {
        // 校驗 checksum
        let checksum = ISPCommandTool.toChecksumBySendBuffer(sendBuffer: sendBuffer)
        let resultChecksum = ISPCommandTool.toChecksumByReadBuffer(readBuffer: readBuffer)
        
        if checksum != resultChecksum {
            print("❌ 校驗和錯誤: 發送=\(checksum), 接收=\(resultChecksum)")
            return false
        }
        
        // 校驗包序號
        let expectedPackNo = packetNumber + 1
        let resultPackNo = ISPCommandTool.toPackNo(readBuffer: readBuffer)
        
        if expectedPackNo != resultPackNo {
            print("❌ 包序號錯誤: 期望=\(expectedPackNo), 實際=\(resultPackNo)")
            return false
        }
        
        // 更新包序號
        packetNumber = expectedPackNo + 1
        
        return true
    }
}
