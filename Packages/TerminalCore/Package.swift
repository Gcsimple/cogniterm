// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
    ],
    targets: [
        .target(name: "CptyShim", publicHeadersPath: "include"),
        .target(name: "TerminalCore", dependencies: ["CptyShim"]),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"]),
    ]
)
