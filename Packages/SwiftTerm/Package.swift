// swift-tools-version:6.0
//
// 本文件由 scripts/vendor-swiftterm.sh 生成，**不要手改**。
//
// 与上游 Package.swift 的差异（每一项都是刻意的）：
//   - 没有构建插件：本机 SwiftPM 插件服务跑在它自己的 sandbox 里，会挂。
//     插件产出的两个文件已由 vendor 脚本用**上游生成器**预生成在 Sources/SwiftTerm/Generated/。
//   - 没有远程依赖：只保留 macOS 目标真正需要的那部分源码，
//     上游的 swift-argument-parser / swift-docc-plugin / swift-png 都是 Linux/WASM/文档向的。
//   - 没有 traits：那是 SwiftPM 6.2 的嵌入式/WASM 分支才需要的东西。
//   - swiftLanguageModes 给 .v6：上游源码就按 Swift 6 写；
//     消费方（CogniTerm App）自己仍是 Swift 5 模式，两者互不影响。
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm"
        ),
    ],
    swiftLanguageModes: [.v6]
)
