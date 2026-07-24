//
//  USBDevice.swift
//  NuISPCmdLineTool-ASUS
//
//  移植自 GUI 版本的 RFDevice.swift
//  简化为命令行版本，移除 GUI 依赖
//

import Foundation
import IOKit
import IOKit.hid

/// USB HID 设备信息结构
struct HIDDeviceInfo {
    let device: IOHIDDevice
    let vendorID: Int
    let productID: Int
    let reportSize: Int
}

/// 除錯用逐包 hex dump 開關。
/// 燒錄大檔案時每包都印出完整 hex 內容（透過 --verbose 開啟）會產生數千至數萬次
/// 終端機輸出，實測對總燒錄時間有可觀察的影響，因此預設關閉，僅保留必要狀態訊息。
enum ISPLogConfig {
    nonisolated(unsafe) static var verboseHex = false
}

/// USB HID 设备通信类
class USBDevice {
    private let deviceInfo: HIDDeviceInfo
    private var receiveBuffer: Data?
    private let bufferQueue = DispatchQueue(label: "com.nuisp.usb.buffer")

    // 回應信號量：由 HID 回呼直接 signal，讓 read() 不需要自己輪詢
    private let responseSemaphore = DispatchSemaphore(value: 0)

    // 專用背景執行緒：持續驅動 RunLoop，讓 HID 回呼不受 read() 呼叫時機限制，
    // 避免原本每次 read() 才自己驅動 1ms RunLoop 輪詢所帶來的額外延遲。
    private var pumpThread: Thread?
    private var deviceRunLoop: CFRunLoop?
    private var shouldStopPump = false
    private let pumpReadySemaphore = DispatchSemaphore(value: 0)
    
    /// 初始化 USB 设备
    /// - Parameter deviceInfo: HID 设备信息
    init(_ deviceInfo: HIDDeviceInfo) {
        self.deviceInfo = deviceInfo
        startPumpThread()
        setupInputReportCallback()
    }

    /// 啟動專用背景執行緒並持續驅動其 RunLoop
    ///
    /// HID 裝置需排程到某個 RunLoop 才能收到回呼；改用獨立且持續運作的背景執行緒，
    /// 而非僅在 read() 呼叫當下才臨時驅動，讓回呼觸發不受 read() 呼叫時機影響，
    /// 藉此降低 read() 的等待延遲（改用 semaphore 直接等待，不再逐毫秒輪詢）。
    private func startPumpThread() {
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            self.deviceRunLoop = CFRunLoopGetCurrent()
            self.pumpReadySemaphore.signal()
            while !self.shouldStopPump {
                CFRunLoopRunInMode(.defaultMode, 0.05, false)
            }
        }
        thread.name = "com.nuisp.usb.pump"
        thread.start()
        pumpThread = thread
        pumpReadySemaphore.wait()
    }
    
    /// 设置输入报告回调
    private func setupInputReportCallback() {
        // 命令列程式必須明確開啟設備（GUI 版透過 IOHIDManagerOpen 隱式開啟）
        let openResult = IOHIDDeviceOpen(deviceInfo.device, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            print("⚠️  IOHIDDeviceOpen 警告: 0x\(String(format: "%08X", openResult))")
        }
        
        // 排程到專用背景執行緒的 RunLoop（而非呼叫端執行緒），確保持續被驅動
        IOHIDDeviceScheduleWithRunLoop(
            deviceInfo.device,
            deviceRunLoop!,
            CFRunLoopMode.defaultMode!.rawValue
        )
        
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: deviceInfo.reportSize)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        IOHIDDeviceRegisterInputReportCallback(
            deviceInfo.device,
            buffer,
            deviceInfo.reportSize,
            { context, result, sender, type, reportID, report, reportLength in
                guard let context = context else { return }
                let device = Unmanaged<USBDevice>.fromOpaque(context).takeUnretainedValue()
                
                let data = Data(bytes: report, count: reportLength)
                device.bufferQueue.async {
                    device.receiveBuffer = data
                    device.responseSemaphore.signal()
                }
            },
            selfPointer
        )
    }
    
    /// 關閉設備並取消 RunLoop 排程
    func close() {
        shouldStopPump = true
        if let loop = deviceRunLoop {
            IOHIDDeviceUnscheduleFromRunLoop(
                deviceInfo.device,
                loop,
                CFRunLoopMode.defaultMode!.rawValue
            )
            CFRunLoopStop(loop)
        }
        IOHIDDeviceClose(deviceInfo.device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    
    deinit {
        close()
    }
    
    /// 写入数据到 USB 设备
    /// - Parameters:
    ///   - data: 要发送的数据
    ///   - interfaceType: 接口类型
    func write(_ data: [UInt8], interfaceType: NulinkInterfaceType = .usb) {
        // 同步清除舊回應，並清空殘留的號誌計數，確保接下來 read() 只會拿到本次的新回應
        bufferQueue.sync {
            self.receiveBuffer = nil
        }
        while responseSemaphore.wait(timeout: .now()) == .success { }
        
        var bytesArray = data
        // 修改第二个字节为接口类型
        if bytesArray.count > 1 {
            bytesArray[1] = interfaceType.rawValue
        }
        
        guard bytesArray.count <= deviceInfo.reportSize else {
            print("錯誤：資料大小 \(bytesArray.count) 超過 USB 報告大小 \(deviceInfo.reportSize)")
            return
        }
        
        // 补足到 reportSize
        while bytesArray.count < deviceInfo.reportSize {
            bytesArray.append(0x00)
        }
        
        let correctData = Data(bytesArray)
        
        let result = IOHIDDeviceSetReport(
            deviceInfo.device,
            kIOHIDReportTypeOutput,
            CFIndex(0),
            (correctData as NSData).bytes.bindMemory(to: UInt8.self, capacity: correctData.count),
            correctData.count
        )
        
        if result == kIOReturnSuccess {
            if ISPLogConfig.verboseHex {
                print("📤 USB 發送: \(correctData.toHexStringWithSpaces())")
            }
        } else {
            print("❌ USB 發送失敗: \(result)")
        }
    }
    
    /// 讀取資料（同步等待）
    /// - Parameter timeout: 逾時時間（秒）
    /// - Returns: 接收到的資料，逾時返回 nil
    func read(timeout: TimeInterval = 8.0) -> Data? {
        // 直接等待 HID 回呼觸發的號誌，而非逐毫秒輪詢 RunLoop，
        // 回呼由專用背景執行緒的 RunLoop 持續驅動，觸發後立即 signal。
        guard responseSemaphore.wait(timeout: .now() + timeout) == .success else {
            print("⏱️ USB 讀取逾時")
            return nil
        }
        
        var buffer: Data?
        bufferQueue.sync {
            buffer = receiveBuffer
        }
        
        if let data = buffer {
            if ISPLogConfig.verboseHex {
                print("📥 USB 接收: \(data.toHexStringWithSpaces())")
            }
            return data
        }
        
        print("⏱️ USB 讀取逾時")
        return nil
    }
    
    /// 清除接收缓冲区（非同步）
    func clearBuffer() {
        bufferQueue.async {
            self.receiveBuffer = nil
        }
    }
}

// MARK: - USB 设备管理器
class USBDeviceManager: @unchecked Sendable {
    static let shared = USBDeviceManager()
    
    private var hidManager: IOHIDManager?
    
    private init() {}
    
    /// Nu-Link2-Pro 轉接器 PID（SPI/I2C/RS485/CAN 皆共用此 PID，僅 tag byte 不同）
    private static let PID_NULINK2: Int = 0x3F10   // 16144
    /// 一般 USB ISP 裝置 PID
    private static let PID_USB: Int = 0x3F00       // 16128

    /// 查找 Nuvoton ISP 設備
    /// - Parameter interfaceType: 目前選定的介面類型，用來決定優先挑選的 PID
    ///   （USB → 0x3F00；SPI/I2C/RS485/CAN → 0x3F10／Nu-Link2-Pro，比照 mac GUI 版裝置挑選邏輯）
    /// - Returns: 找到的設備資訊，未找到返回 nil
    func findNuvotonDevice(interfaceType: NulinkInterfaceType = .usb) -> HIDDeviceInfo? {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        guard let manager = hidManager else {
            print("❌ 無法建立 HID 管理器")
            return nil
        }
        
        // 设置匹配条件（可以指定 VID/PID）
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            print("❌ 未找到 HID 設備")
            return nil
        }
        
        // 支援的 ISP 設備清單（VID, PID）；PID 為 nil 表示符合該 VID 的所有 PID
        let supportedDevices: [(vid: Int, pid: Int?, label: String)] = [
            (0x0416, nil,    "Nuvoton ISP"),   // Nuvoton 全系列
            (0x0B05, nil, "Test ISP"),      // ASUS VID/PID
        ]

        // 依偏好 PID 挑選：SPI/I2C/RS485/CAN 走 Nu-Link2-Pro（0x3F10），USB 走一般 ISP 裝置（0x3F00）
        let preferredPID: Int
        switch interfaceType {
        case .spi, .i2c, .rs485, .can:
            preferredPID = USBDeviceManager.PID_NULINK2
        default:
            preferredPID = USBDeviceManager.PID_USB
        }

        // 收集所有符合 VID 的裝置
        var matchedDevices: [(device: IOHIDDevice, vendorID: Int, productID: Int, label: String)] = []
        for device in deviceSet {
            if let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
               let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int {

                for entry in supportedDevices {
                    let vidMatch = vendorID == entry.vid
                    let pidMatch = entry.pid == nil || productID == entry.pid!

                    if vidMatch && pidMatch {
                        matchedDevices.append((device: device, vendorID: vendorID, productID: productID, label: entry.label))
                        break
                    }
                }
            }
        }

        guard !matchedDevices.isEmpty else {
            print("❌ 未找到支援的 ISP 設備（Nuvoton VID: 0x0416 / ASUS VID: 0x0B05 PID: 0x1D27）")
            return nil
        }

        // 優先挑選符合偏好 PID 的裝置，找不到則回退為第一個符合 VID 的裝置
        let chosen = matchedDevices.first(where: { $0.productID == preferredPID }) ?? matchedDevices[0]

        let reportSize = IOHIDDeviceGetProperty(chosen.device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
        let outputReportSize = IOHIDDeviceGetProperty(chosen.device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int
        let featureReportSize = IOHIDDeviceGetProperty(chosen.device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int

        print("✅ 找到 \(chosen.label) 設備:")
        print("   VID: 0x\(String(format: "%04X", chosen.vendorID))")
        print("   PID: 0x\(String(format: "%04X", chosen.productID))")
        print("   介面類型: \(interfaceType)")
        print("   報告大小 (Input): \(reportSize) 位元組")
        print("   報告大小 (Output): \(outputReportSize.map { String($0) } ?? "N/A") 位元組")
        print("   報告大小 (Feature): \(featureReportSize.map { String($0) } ?? "N/A") 位元組")

        return HIDDeviceInfo(
            device: chosen.device,
            vendorID: chosen.vendorID,
            productID: chosen.productID,
            reportSize: reportSize
        )
    }
    
    /// 关闭 HID 管理器
    func close() {
        if let manager = hidManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}
