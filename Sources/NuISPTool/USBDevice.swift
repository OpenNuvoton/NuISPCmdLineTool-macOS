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

/// USB HID 设备通信类
class USBDevice {
    private let deviceInfo: HIDDeviceInfo
    private var receiveBuffer: Data?
    private let bufferQueue = DispatchQueue(label: "com.nuisp.usb.buffer")
    
    /// 初始化 USB 设备
    /// - Parameter deviceInfo: HID 设备信息
    init(_ deviceInfo: HIDDeviceInfo) {
        self.deviceInfo = deviceInfo
        setupInputReportCallback()
    }
    
    /// 设置输入报告回调
    private func setupInputReportCallback() {
        // 命令列程式必須明確開啟設備（GUI 版透過 IOHIDManagerOpen 隱式開啟）
        let openResult = IOHIDDeviceOpen(deviceInfo.device, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            print("⚠️  IOHIDDeviceOpen 警告: 0x\(String(format: "%08X", openResult))")
        }
        
        // 命令列程式沒有自動 RunLoop，必須手動將設備排程到當前 RunLoop
        // 否則 IOHIDDeviceRegisterInputReportCallback 的回呼永遠不會觸發
        IOHIDDeviceScheduleWithRunLoop(
            deviceInfo.device,
            CFRunLoopGetCurrent(),
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
                }
            },
            selfPointer
        )
    }
    
    /// 關閉設備並取消 RunLoop 排程
    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            deviceInfo.device,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode!.rawValue
        )
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
        bufferQueue.async {
            self.receiveBuffer = nil
        }
        
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
            print("📤 USB 發送: \(correctData.toHexStringWithSpaces())")
        } else {
            print("❌ USB 發送失敗: \(result)")
        }
    }
    
    /// 讀取資料（同步等待）
    /// - Parameter timeout: 逾時時間（秒）
    /// - Returns: 接收到的資料，逾時返回 nil
    func read(timeout: TimeInterval = 8.0) -> Data? {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            var buffer: Data?
            bufferQueue.sync {
                buffer = receiveBuffer
            }
            
            if let data = buffer {
                print("📥 USB 接收: \(data.toHexStringWithSpaces())")
                return data
            }
            
            // 驅動 RunLoop 讓 HID 回呼得以觸發
            // 命令列程式沒有自動 RunLoop，必須手動執行才能收到 HID 事件
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
        }
        
        print("⏱️ USB 讀取逾時")
        return nil
    }
    
    /// 清除接收缓冲区
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
    
    /// 查找 Nuvoton ISP 設備
    /// - Returns: 找到的設備資訊，未找到返回 nil
    func findNuvotonDevice() -> HIDDeviceInfo? {
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
        
        // 查找 Nuvoton 設備（VID: 0x0416）
        for device in deviceSet {
            if let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
               let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int {
                
                // Nuvoton VID: 0x0416
                if vendorID == 0x0416 {
                    let reportSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
                    
                    print("✅ 找到 Nuvoton 設備:")
                    print("   VID: 0x\(String(format: "%04X", vendorID))")
                    print("   PID: 0x\(String(format: "%04X", productID))")
                    print("   報告大小: \(reportSize) 位元組")
                    
                    return HIDDeviceInfo(
                        device: device,
                        vendorID: vendorID,
                        productID: productID,
                        reportSize: reportSize
                    )
                }
            }
        }
        
        print("❌ 未找到 Nuvoton ISP 設備（VID: 0x0416）")
        return nil
    }
    
    /// 关闭 HID 管理器
    func close() {
        if let manager = hidManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}
