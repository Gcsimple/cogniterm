// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(path: "../PolicyEngine"),
    ],
    targets: [
        .target(name: "Persistence", dependencies: [
            .product(name: "PolicyEngine", package: "PolicyEngine"),
        ]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
    ]
)
