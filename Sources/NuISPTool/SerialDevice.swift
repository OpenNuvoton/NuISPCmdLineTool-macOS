//
//  SerialDevice.swift
//  NuISPCmdLineTool-ASUS
//
//  移植自 GUI 版本的 SerialPortManager.swift
//  简化为命令行版本
//

import Foundation

/// 串口设备管理类
class SerialDevice {
    private var fileHandle: FileHandle?
    private let serialQueue = DispatchQueue(label: "com.nuisp.serial.queue")
    private var timeout: TimeInterval = 6.0
    
    /// 打開串埠
    /// - Parameter portPath: 串埠路徑（如 "/dev/tty.usbserial-xxxx" 或 "COM5"）
    /// - Returns: 是否成功打開
    func open(portPath: String) -> Bool {
        // 嘗試打開串埠檔案
        guard let fileHandle = FileHandle(forUpdatingAtPath: portPath) else {
            print("❌ 無法打開串埠: \(portPath)")
            print("💡 提示: 請確認設備已連接，路徑格式正確")
            print("   macOS: /dev/tty.usbserial-xxxx 或 /dev/cu.usbserial-xxxx")
            return false
        }
        
        self.fileHandle = fileHandle
        
        // 配置串埠參數（波特率 115200）
        let fd = fileHandle.fileDescriptor
        if fd != -1 {
            configureSerialPort(fd)
        }
        
        print("✅ 串埠已打開: \(portPath)")
        return true
    }
    
    /// 配置串口参数
    /// - Parameter fd: 文件描述符
    private func configureSerialPort(_ fd: Int32) {
        var options = termios()
        
        // 获取当前配置
        tcgetattr(fd, &options)
        
        // 设置波特率 115200
        cfsetispeed(&options, speed_t(B115200))
        cfsetospeed(&options, speed_t(B115200))
        
        // 8N1: 8位数据位，无校验，1位停止位
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
        
        // 原始模式
        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        options.c_oflag &= ~tcflag_t(OPOST)
        
        // 设置超时
        options.c_cc.16 = 0  // VMIN
        options.c_cc.17 = 10 // VTIME (1秒)
        
        // 应用配置
        tcsetattr(fd, TCSANOW, &options)
        
        print("📡 串埠配置: 115200 8N1")
    }
    
    /// 關閉串埠
    func close() {
        fileHandle?.closeFile()
        fileHandle = nil
        print("🔒 串埠已關閉")
    }
    
    /// 检查串口是否打开
    func isOpen() -> Bool {
        return fileHandle != nil
    }
    
    /// 写入并读取数据（标准模式）
    /// - Parameter data: 要发送的数据
    /// - Returns: 接收到的数据，超时返回 nil
    func writeAndRead(data: Data) -> Data? {
        guard let fileHandle = fileHandle else {
            print("❌ 串口未打开")
            return nil
        }
        
        let bufferLock = NSLock()
        var sumData = Data()
        
        print("📤 UART 发送: \(data.toHexStringWithSpaces())")
        fileHandle.write(data)
        
        Thread.sleep(forTimeInterval: 0.02)
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.01)
            var continueReading = true
            while continueReading {
                let readData = fileHandle.availableData
                bufferLock.lock()
                sumData.append(readData)
                if sumData.count >= 64 {
                    result = sumData.prefix(64)
                    continueReading = false
                    bufferLock.unlock()
                    semaphore.signal()
                    break
                }
                bufferLock.unlock()
            }
        }
        
        let timeoutResult = semaphore.wait(timeout: .now() + timeout)
        
        if timeoutResult == .success {
            print("📥 UART 接收: \(result!.toHexStringWithSpaces())")
            return result
        } else {
            print("⏱️ UART 读取超时")
            return nil
        }
    }
    
    /// 写入并读取数据（连接模式 - 多次重试）
    /// - Parameter data: 要发送的数据
    /// - Returns: 接收到的数据，超时返回 nil
    func writeForConnect(data: Data) -> Data? {
        guard let fileHandle = fileHandle else {
            print("❌ 串口未打开")
            return nil
        }
        
        guard fileHandle.fileDescriptor != -1 else {
            print("❌ 无效的文件句柄")
            return nil
        }
        
        let bufferLock = NSLock()
        var sumData = Data()
        let stateLock = NSLock()
        var isRead = false
        var isReading = false
        var resultData: Data?
        
        print("📤 UART 连接发送: \(data.toHexStringWithSpaces())")
        
        let queue = DispatchQueue.global(qos: .userInitiated)
        let semaphore = DispatchSemaphore(value: 0)
        
        // 写入线程：每 300ms 发送一次，直到收到响应
        queue.async {
            var continueWriting = true
            while continueWriting {
                stateLock.lock()
                continueWriting = !isReading
                stateLock.unlock()
                if continueWriting {
                    fileHandle.write(data)
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
        }
        
        // 读取线程
        queue.async {
            var continueReading = true
            while continueReading {
                Thread.sleep(forTimeInterval: 0.01)
                let readData = fileHandle.availableData
                
                // 开始接收有效数据
                if !readData.isEmpty && readData.first != 0x00 {
                    stateLock.lock()
                    isReading = true
                    stateLock.unlock()
                }
                
                bufferLock.lock()
                sumData.append(readData)
                
                if sumData.count >= 64 {
                    // 过滤无效开头
                    let firstByte = sumData.first
                    if firstByte == 0x00 || firstByte == 0xFF {
                        sumData.removeFirst()
                        if sumData.count >= 64 {
                            resultData = sumData.prefix(64)
                            continueReading = false
                            bufferLock.unlock()
                            stateLock.lock()
                            isRead = true
                            stateLock.unlock()
                            semaphore.signal()
                            break
                        }
                    } else {
                        resultData = sumData.prefix(64)
                        continueReading = false
                        bufferLock.unlock()
                        stateLock.lock()
                        isRead = true
                        stateLock.unlock()
                        semaphore.signal()
                        break
                    }
                }
                bufferLock.unlock()
            }
        }
        
        // 等待超时
        let timeoutResult = semaphore.wait(timeout: .now() + timeout)
        stateLock.lock()
        isRead = true
        isReading = true
        stateLock.unlock()
        
        if timeoutResult == .timedOut {
            print("⏱️ UART 连接超时")
            return nil
        }
        
        Thread.sleep(forTimeInterval: 0.3)
        
        if let result = resultData {
            print("📥 UART 连接接收: \(result.toHexStringWithSpaces())")
        }
        
        return resultData
    }
}

// MARK: - 串口列表工具
class SerialPortEnumerator {
    /// 列出所有可用的串埠設備
    /// - Returns: 串埠路徑陣列
    static func listSerialPorts() -> [String] {
        var ports: [String] = []
        
        let fileManager = FileManager.default
        
        // macOS 串埠設備路徑
        let devPath = "/dev"
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: devPath)
            
            for file in files {
                // 查找 tty.* 或 cu.* 設備
                if file.hasPrefix("tty.") || file.hasPrefix("cu.") {
                    // 過濾藍牙和內部設備
                    if !file.contains("Bluetooth") && !file.contains("SOC") {
                        ports.append("\(devPath)/\(file)")
                    }
                }
            }
        } catch {
            print("❌ 無法列出串埠設備: \(error)")
        }
        
        return ports.sorted()
    }
    
    /// 列印可用串埠列表
    static func printAvailablePorts() {
        let ports = listSerialPorts()
        
        if ports.isEmpty {
            print("⚠️  未找到可用的串埠設備")
        } else {
            print("📋 可用的串埠設備:")
            for (index, port) in ports.enumerated() {
                print("   \(index + 1). \(port)")
            }
        }
    }
}
