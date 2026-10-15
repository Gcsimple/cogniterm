// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SessionLogReader",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SessionLogReader", targets: ["SessionLogReader"]),
    ],
    dependencies: [
        .package(path: "../AcpClient"),
    ],
    targets: [
        .target(name: "SessionLogReader", dependencies: [
            .product(name: "AcpClient", package: "AcpClient"),
        ]),
        .testTarget(name: "SessionLogReaderTests", dependencies: ["SessionLogReader"]),
    ]
)
