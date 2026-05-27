// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NuISPCmdLineTool-ASUS",  // 保持项目名称不变
    platforms: [
        .macOS(.v13)  // 指定最低支持 macOS 13
    ],
    dependencies: [
        // 加入參數解析庫，這能讓指令格式與 Nuvoton 手冊完全一致
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "NuISPTool",  // 可执行文件名称简化
            dependencies: [
                // 連結解析庫
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [
                // Flash.py, PartNumID.py, FlashInfo.py 由 --update-db 自動更新
                .copy("Resources"),
            ]
        ),
    ]
)