import Foundation
import ArgumentParser

// 使用 @main 標記為程式進入點，Swift 6.2 的標準寫法
@main
struct NuISPTool: ParsableCommand {
    
    
    // 設定指令的基本資訊，讓 --help 顯示正確名稱
    static let configuration = CommandConfiguration(
        commandName: "NuISPTool",
        abstract: "Nuvoton NuMicro ISP 命令列工具",
        discussion: """
        支援透過 USB 或 UART 介面對 Nuvoton 微控制器進行 ISP 編程。
        SPI/I2C/RS485/CAN 介面需搭配 Nu-Link2-Pro 轉接器（尚未支援）。
        
        使用範例:
          # USB 介面更新 APROM（預設介面）
          NuISPTool -a firmware.bin
          NuISPTool -o USB -a firmware.bin
          
          # UART 介面更新 APROM
          NuISPTool -o UART /dev/tty.usbserial-xxx -a firmware.bin
          
          # 更新配置（空格分隔多個值）
          NuISPTool -o USB -c 0xFFFFFF7E 0xFFFFFFFF
          
          # 全片抹除
          NuISPTool -o USB -e
        """
    )

    // 連接介面: 手冊定義包含介面名稱與選填選項，預設為 USB
    @Option(name: .short, help: "指定介面 (USB, UART)；SPI/I2C/RS485/CAN 需 Nu-Link2-Pro 硬體")
    var o: [String] = []

    // APROM 更新檔案路徑
    @Option(name: .short, help: "燒錄 APROM 的 BIN 檔案路徑")
    var a: String?

    // Data Flash 更新檔案路徑
    @Option(name: .short, help: "燒錄 Data Flash 的 BIN 檔案路徑")
    var d: String?

    // User Configuration 位元設定（支援空格分隔多值：-c 0x12345678 0xABCDEF00）
    @Option(name: .short, parsing: .upToNextOption, help: "更新 Config 值 (需為 8 位 16 進位，如 0x12345678)")
    var c: [String] = []

    // 抹除指令
    @Flag(name: .short, help: "執行全片抹除 (Erase)")
    var e: Bool = false
    
    // 列出串口設備
    @Flag(name: .long, help: "列出可用的串埠設備")
    var listPorts: Bool = false

    // 從 GitHub 更新晶片數據庫
    @Flag(name: .long, help: "從官方 GitHub 更新晶片規格數據庫（需網路連線）")
    var updateDB: Bool = false

    // 程式的主要邏輯執行處
    func run() throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🛠  Nuvoton ISP 命令列工具 v1.0")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 列出串口設備
        if listPorts {
            SerialPortEnumerator.printAvailablePorts()
            return
        }
        
        // 更新晶片數據庫
        if updateDB {
            let success = ISPManager.shared.updateDB()
            throw success ? ExitCode.success : ExitCode(1)
        }
        
        // 解析介面與選項
        let interface = o.isEmpty ? "USB" : o[0].uppercased()
        let intfOption = o.count > 1 ? o[1] : nil
        
        print("🔗 通訊介面: \(interface)")
        if let option = intfOption {
            print("📍 介面參數: \(option)")
        }
        
        // 檢查操作互斥性
        let operationCount = [a != nil, d != nil, !c.isEmpty, e].filter { $0 }.count
        guard operationCount <= 1 else {
            print("\n❌ 錯誤: 不能同時執行多個操作")
            print("💡 提示: 請只選擇一個操作 (-a, -d, -c, 或 -e)")
            throw ExitCode.validationFailure
        }
        
        // 檢查是否有操作
        guard operationCount > 0 else {
            print("\n💡 提示: 未指定操作。請使用 --help 查看用法。")
            return
        }
        
        // 初始化 ISP 管理器
        let isp = ISPManager.shared
        
        // 連接設備
        let connected: Bool
        switch interface {
        case "USB":
            connected = isp.connectUSB()
        case "UART":
            guard let port = intfOption else {
                print("❌ 錯誤: UART 介面需要指定埠路徑")
                print("💡 提示: 使用 --list-ports 查看可用埠")
                throw ExitCode.validationFailure
            }
            connected = isp.connectUART(portPath: port)
        default:
            print("❌ 錯誤: 暫不支援介面類型: \(interface)")
            print("💡 提示: 目前支援 USB 和 UART")
            throw ExitCode.validationFailure
        }
        
        guard connected else {
            print("\n❌ 設備連接失敗")
            throw ExitCode.failure
        }
        
        // 發送連接命令
        var result = isp.sendConnect()
        guard result.success else {
            print("❌ \(result.message)")
            isp.disconnect()
            throw ExitCode.failure
        }
        
        // 獲取設備資訊
        result = isp.getDeviceID()
        if !result.success {
            print("⚠️  無法讀取設備 ID: \(result.message)")
        }
        
        print("")
        
        // 執行操作
        if let binPath = a {
            // 更新 APROM
            result = isp.updateAPROM(filePath: binPath)
            
        } else if let binPath = d {
            // 更新 Data Flash
            print("⚠️  Data Flash 需要指定起始位址")
            print("💡 目前預設使用 0x0，請根據晶片規格調整")
            result = isp.updateDataFlash(filePath: binPath, startAddress: 0x0)
            
        } else if !c.isEmpty {
            // 更新配置
            var configs: [UInt] = []
            for configStr in c {
                guard let value = configStr.parseHexToUInt() else {
                    print("❌ 錯誤: 無效的配置值 '\(configStr)'")
                    print("💡 提示: 配置值應為 8 位十六進位，如 0x12345678")
                    isp.disconnect()
                    throw ExitCode.validationFailure
                }
                configs.append(value)
            }
            result = isp.updateConfig(configs: configs)
            
        } else if e {
            // 全片抹除
            result = isp.eraseAll()
        }
        
        // 顯示結果
        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        if result.success {
            print("✅ 操作完成: \(result.message)")
            
            // 執行 APROM（如果更新了韌體）
            if a != nil || d != nil {
                print("\n🚀 正在啟動應用程式...")
                let runResult = isp.runAPROM()
                if runResult.success {
                    print("✅ 設備已重啟")
                }
            }
        } else {
            print("❌ 操作失敗: \(result.message)")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 中斷連接
        isp.disconnect()
        
        if !result.success {
            throw ExitCode.failure
        }
    }
}