//
//  ISPManager.swift
//  NuISPCmdLineTool-ASUS
//
//  移植自 GUI 版本的 ISPManager.swift
//  简化为命令行版本，移除 GUI 依赖
//

import Foundation

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
    
    // 配置
    private var interfaceType: NulinkInterfaceType = .usb
    private var packetNumber: UInt = 0x00000001
    private let timeout: TimeInterval = 8.0
    
    private init() {}
    
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
        
        let deviceID = ISPCommandTool.toDeviceID(readBuffer: readBuffer)
        print("✅ 設備 ID: 0x\(deviceID)")
        
        return .success(data: Data(readBuffer), message: "設備 ID: 0x\(deviceID)")
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
    
    /// 更新配置
    /// - Parameter configs: 配置值陣列
    /// - Returns: 操作結果
    func updateConfig(configs: [UInt]) -> ISPResult {
        print("⚙️  更新設備配置...")
        print("   配置值: \(configs.map { "0x" + String(format: "%08X", $0) }.joined(separator: ", "))")
        
        let sendBuffer = ISPCommandTool.toUpdateConfigCMD(configs: configs, packetNumber: packetNumber)
        
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
            
            guard validateResponse(sendBuffer: sendBuffer, readBuffer: readBuffer) else {
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
