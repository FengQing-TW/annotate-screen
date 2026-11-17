// swift-tools-version:6.0
// AnnotateScreen：macOS 螢幕註釋工具（2026-11-13）
import PackageDescription

let package = Package(
    name: "AnnotateScreen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AnnotateScreen", targets: ["AnnotateScreen"]),
    ],
    targets: [
        // 純模型：只 import Foundation、CoreGraphics
        .target(name: "AnnotateCore"),
        // AppKit 介面、視窗、熱鍵、截圖
        .executableTarget(name: "AnnotateScreen", dependencies: ["AnnotateCore"]),
        // Swift Testing 單元測試
        .testTarget(name: "AnnotateCoreTests", dependencies: ["AnnotateCore"]),
    ],
    swiftLanguageModes: [.v5]
)
