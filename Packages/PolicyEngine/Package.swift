// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PolicyEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PolicyEngine", targets: ["PolicyEngine"]),
    ],
    targets: [
        .target(name: "PolicyEngine"),
        .testTarget(name: "PolicyEngineTests", dependencies: ["PolicyEngine"]),
    ]
)
