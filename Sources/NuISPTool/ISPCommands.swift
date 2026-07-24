//
//  ISPCommands.swift
//  NuISPCmdLineTool-ASUS
//
//  移植自 GUI 版本的 ISPCommands.swift
//

import Foundation

/// ISP 命令枚举
enum ISPCommands: UInt {
    case CMD_REMAIN_PACKET = 0x00000000
    case CMD_UPDATE_APROM = 0x000000A0
    case CMD_UPDATE_CONFIG = 0x000000A1
    case CMD_READ_CONFIG = 0x000000A2
    case CMD_ERASE_ALL = 0x000000A3
    case CMD_SYNC_PACKNO = 0x000000A4
    case CMD_GET_FWVER = 0x000000A6
    case CMD_GET_DEVICEID = 0x000000B1
    case CMD_UPDATE_DATAFLASH = 0x000000C3
    case CMD_RUN_APROM = 0x000000AB
    case CMD_RUN_LDROM = 0x000000AC
    case CMD_RESET = 0x000000AD
    case CMD_CONNECT = 0x000000AE
    case CMD_RESEND_PACKET = 0x000000FF
    // Support SPI Flash
    case CMD_ERASE_SPIFLASH = 0x000000D0
    case CMD_UPDATE_SPIFLASH = 0x000000D1
}

/// CAN 接口专用命令（封包格式與一般 USB/UART 完全不同，移植自 Android 版 ISPCommandTool.kt）
/// 註：Android 版的 CMD_CAN_UPDATE_APROM 與 CMD_CAN_RUN_APROM 皆為 0xAB000000（Kotlin 允許重複 raw value，
/// Swift 不允許），且 toUpdateBinCANCMD 實際上不使用 CMD word，故此處不重複定義該 case。
enum ISPCanCommands: UInt {
    case CMD_CAN_READ_CONFIG = 0xA2000000
    case CMD_CAN_GET_DEVICE = 0xB1000000
    case CMD_CAN_RUN_APROM = 0xAB000000
}

/// 接口类型枚举
enum NulinkInterfaceType {
    case usb
    case uart
    case spi
    case i2c
    case rs485
    case can
    case wifi
    case ble
    
    var rawValue: UInt8 {
        switch self {
        case .usb, .uart:
            return 0x00
        case .spi:
            return 0x03
        case .i2c:
            return 0x04
        case .rs485:
            return 0x05
        case .can:
            return 0x06
        case .wifi:
            return 0x07
        case .ble:
            return 0x08
        }
    }
}

// MARK: - ISP 命令工具类
class ISPCommandTool {
    
    /// 生成基本命令数据包（64 字节）
    /// - Parameters:
    ///   - cmd: ISP 命令
    ///   - packetNumber: 数据包序号
    /// - Returns: 64 字节的命令数组
    static func toCMD(cmd: ISPCommands, packetNumber: UInt) -> [UInt8] {
        let cmdBytes = cmd.rawValue.UIntTo4Bytes()
        let packetNumberBytes = packetNumber.UIntTo4Bytes()
        let noneBytes: [UInt8] = Array(repeating: 0x00, count: 56)
        
        var sendBytes = [UInt8]()
        sendBytes += cmdBytes
        sendBytes += packetNumberBytes
        sendBytes += noneBytes
        
        return sendBytes
    }
    
    /// 计算发送缓冲区的校验和
    /// - Parameter sendBuffer: 发送的数据包
    /// - Returns: 校验和
    static func toChecksumBySendBuffer(sendBuffer: [UInt8]) -> UInt {
        var sendBuffer = sendBuffer
        sendBuffer[1] = 0x00 // 将不同 interface 所偷改的修正回来
        var sum: UInt = 0
        for byte in sendBuffer {
            sum += UInt(byte)
        }
        return sum
    }
    
    /// 从接收缓冲区解析校验和
    /// - Parameter readBuffer: 接收的数据包
    /// - Returns: 校验和
    static func toChecksumByReadBuffer(readBuffer: [UInt8]) -> UInt {
        let bytes: [UInt8] = [readBuffer[0], readBuffer[1], readBuffer[2], readBuffer[3]]
        let values = bytes.map { Int($0) }
        
        let result = values.enumerated().reduce(0) { (acc, tuple) in
            let (index, value) = tuple
            return acc + (value << (index * 8))
        }
        return UInt(result)
    }
    
    /// 从接收缓冲区解析包序号
    /// - Parameter readBuffer: 接收的数据包
    /// - Returns: 包序号
    static func toPackNo(readBuffer: [UInt8]) -> UInt {
        let bytes: [UInt8] = [readBuffer[4], readBuffer[5], readBuffer[6], readBuffer[7]]
        let values = bytes.map { Int($0) }
        
        let result = values.enumerated().reduce(0) { (acc, tuple) in
            let (index, value) = tuple
            return acc + (value << (index * 8))
        }
        return UInt(result)
    }
    
    /// 从接收缓冲区解析设备 ID
    /// - Parameter readBuffer: 接收的数据包
    /// - Returns: 设备 ID 的十六进制字符串
    static func toDeviceID(readBuffer: [UInt8]) -> String {
        let deviceIDArray: [UInt8] = [readBuffer[11], readBuffer[10], readBuffer[9], readBuffer[8]]
        return Data(deviceIDArray).toHexString()
    }
    
    /// 从接收缓冲区解析固件版本
    /// - Parameter readBuffer: 接收的数据包
    /// - Returns: 固件版本的十六进制字符串
    static func toFirmwareVersion(readBuffer: [UInt8]) -> String? {
        let deviceIDArray: [UInt8] = [
            readBuffer[11], readBuffer[10], readBuffer[9], readBuffer[8]
        ]
        let deviceIDData = Data(deviceIDArray)
        let byte: UInt8 = readBuffer[8]
        let data = Data([byte])
        return data.toHexString()
    }
    
    /// 生成更新配置命令数据包
    /// - Parameters:
    ///   - configs: 配置值数组
    ///   - packetNumber: 数据包序号
    /// - Returns: 64 字节的命令数组
    static func toUpdateConfigCMD(configs: [UInt], packetNumber: UInt) -> [UInt8] {
        let cmdBytes = ISPCommands.CMD_UPDATE_CONFIG.rawValue.UIntTo4Bytes()
        let packetNumberBytes = packetNumber.UIntTo4Bytes()
        
        var sendBytes: [UInt8] = []
        sendBytes += cmdBytes
        sendBytes += packetNumberBytes
        
        for config in configs {
            sendBytes += config.UIntTo4Bytes()
        }
        
        // 补足至 64 bytes
        let currentLength = sendBytes.count
        if currentLength < 64 {
            let paddingLength = 64 - currentLength
            let paddingBytes: [UInt8] = Array(repeating: 0x00, count: paddingLength)
            sendBytes += paddingBytes
        }
        
        return sendBytes
    }
    
    /// 生成更新二进制文件命令数据包（APROM 或 Data Flash）
    /// - Parameters:
    ///   - cmd: 命令类型（UPDATE_APROM 或 UPDATE_DATAFLASH）
    ///   - packetNumber: 数据包序号
    ///   - startAddress: 起始地址
    ///   - size: 总大小
    ///   - data: 数据
    ///   - isFirst: 是否为第一个数据包
    /// - Returns: 64 字节的命令数组
    static func toUpdateBinCMD(
        cmd: ISPCommands,
        packetNumber: UInt,
        startAddress: UInt,
        size: Int,
        data: Data,
        isFirst: Bool
    ) -> [UInt8] {
        var sendBytes = [UInt8]()
        
        if isFirst {
            // 第一个数据包
            let cmdBytes = cmd.rawValue.UIntTo4Bytes()
            let packetNumberBytes = packetNumber.UIntTo4Bytes()
            let addressBytes = startAddress.UIntTo4Bytes()
            let totalSizeBytes = UInt(size).UIntTo4Bytes()
            
            sendBytes += cmdBytes
            sendBytes += packetNumberBytes
            sendBytes += addressBytes
            sendBytes += totalSizeBytes
            sendBytes += data
        } else {
            // 后续数据包
            let cmdBytes = UInt(0x00000000).UIntTo4Bytes()
            let packetNumberBytes = packetNumber.UIntTo4Bytes()
            
            sendBytes += cmdBytes
            sendBytes += packetNumberBytes
            sendBytes += data
        }
        
        return sendBytes
    }

    // MARK: - CAN 專屬封包組裝（移植自 Android 版 ISPCommandTool.kt，封包格式與一般版不同，且無 checksum/packetNumber）

    /// CAN：RUN_APROM 封包 [0x00,0x00] + 4-byte CMD（高位版本）+ 補零到 64
    static func toCanRunAPROMCMD() -> [UInt8] {
        var sendBytes: [UInt8] = [0x00, 0x00]
        sendBytes += ISPCanCommands.CMD_CAN_RUN_APROM.rawValue.UIntTo4Bytes()
        while sendBytes.count < 64 {
            sendBytes.append(0x00)
        }
        return sendBytes
    }

    /// CAN：GET_DEVICE 封包 [0x00,0x00] + 4-byte CMD（高位版本）+ 補零到 64
    static func toCanGetDeviceCMD() -> [UInt8] {
        var sendBytes: [UInt8] = [0x00, 0x00]
        sendBytes += ISPCanCommands.CMD_CAN_GET_DEVICE.rawValue.UIntTo4Bytes()
        while sendBytes.count < 64 {
            sendBytes.append(0x00)
        }
        return sendBytes
    }

    /// CAN：READ_CONFIG 封包（index 0~3 對應 CONFIG0~3，須分 4 次個別讀取）
    /// [0x00,0x00] + 4-byte CMD_CAN_READ_CONFIG + 4-byte 固定位址 + 補零到 64
    static func toCanReadConfigCMD(index: Int) -> [UInt8] {
        let configAddress: [UInt8]
        switch index {
        case 1: configAddress = [0x04, 0x00, 0x30, 0x00]
        case 2: configAddress = [0x08, 0x00, 0x30, 0x00]
        case 3: configAddress = [0x12, 0x00, 0x30, 0x00]
        default: configAddress = [0x00, 0x00, 0x30, 0x00] // index 0
        }

        var sendBytes: [UInt8] = [0x00, 0x00]
        sendBytes += ISPCanCommands.CMD_CAN_READ_CONFIG.rawValue.UIntTo4Bytes()
        sendBytes += configAddress
        while sendBytes.count < 64 {
            sendBytes.append(0x00)
        }
        return sendBytes
    }

    /// CAN：UPDATE_CONFIG 封包（index 0~3 對應 CONFIG0~3，須分 4 次個別寫入，無 CMD word）
    /// [0x00,0x00] + 4-byte 固定位址 + 4-byte config 值 + 補零到 64
    static func toCanUpdateConfigCMD(index: Int, value: UInt) -> [UInt8] {
        let configAddress: [UInt8]
        switch index {
        case 1: configAddress = [0x04, 0x00, 0x30, 0x00]
        case 2: configAddress = [0x08, 0x00, 0x30, 0x00]
        case 3: configAddress = [0x12, 0x00, 0x30, 0x00]
        default: configAddress = [0x00, 0x00, 0x30, 0x00] // index 0
        }

        var sendBytes: [UInt8] = [0x00, 0x00]
        sendBytes += configAddress
        sendBytes += value.UIntTo4Bytes()
        while sendBytes.count < 64 {
            sendBytes.append(0x00)
        }
        return sendBytes
    }

    /// CAN：燒錄 APROM/Data Flash 封包（無 CMD word，資料以 4 bytes 為一個分包單位）
    /// [0x00,0x00] + 4-byte 位址 + data + 補零到 64
    static func toUpdateBinCANCMD(startAddress: [UInt8], data: [UInt8]) -> [UInt8] {
        var sendBytes: [UInt8] = [0x00, 0x00]
        sendBytes += startAddress
        sendBytes += data
        while sendBytes.count < 64 {
            sendBytes.append(0x00)
        }
        return sendBytes
    }

    /// CAN：從回應解析裝置 ID（bytes[7,6,5,4]，一般版是 [11,10,9,8]，因 CAN 回應少了 4-byte packet number 欄位）
    static func toCANDeviceID(readBuffer: [UInt8]) -> String {
        let deviceIDArray: [UInt8] = [readBuffer[7], readBuffer[6], readBuffer[5], readBuffer[4]]
        return Data(deviceIDArray).toHexString()
    }
}
