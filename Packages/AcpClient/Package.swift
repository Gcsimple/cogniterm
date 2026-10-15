// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AcpClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AcpClient", targets: ["AcpClient"]),
    ],
    targets: [
        .target(name: "AcpClient"),
        .testTarget(name: "AcpClientTests", dependencies: ["AcpClient"]),
    ]
)
