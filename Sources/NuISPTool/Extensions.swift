//
//  Extensions.swift
//  NuISPCmdLineTool-ASUS
//
//  移植自 GUI 版本的 HexTool.swift
//

import Foundation

// MARK: - UInt Extensions
extension UInt {
    /// 将 UInt 转换为 4 字节数组 (Little-endian)
    func UIntTo4Bytes() -> [UInt8] {
        return [
            UInt8(self & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 24) & 0xFF)
        ]
    }
}

// MARK: - Array Extensions
extension Array where Element == UInt8 {
    /// 将字节数组转换为十六进制字符串
    func toHexString() -> String {
        return self.map { String(format: "%02X", $0) }.joined()
    }
    
    /// 将字节数组转换为带空格的十六进制字符串（便于阅读）
    func toHexStringWithSpaces() -> String {
        return self.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: - Data Extensions
extension Data {
    /// 将 Data 转换为十六进制字符串
    func toHexString() -> String {
        return map { String(format: "%02X", $0) }.joined()
    }
    
    /// 将 Data 转换为 UInt8 数组
    var toUint8Array: [UInt8] {
        return [UInt8](self)
    }
    
    /// 将 Data 转换为带空格的十六进制字符串（便于阅读）
    func toHexStringWithSpaces() -> String {
        return map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: - String Extensions
extension String {
    /// 从十六进制字符串解析为 UInt（支持 0x 前缀）
    func parseHexToUInt() -> UInt? {
        let cleaned = self.hasPrefix("0x") ? String(self.dropFirst(2)) : self
        return UInt(cleaned, radix: 16)
    }
}
