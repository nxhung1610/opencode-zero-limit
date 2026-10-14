// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelayDock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RelayDock", targets: ["RelayDock"]),
        .library(name: "RelayDockCore", targets: ["RelayDockCore"]),
    ],
    targets: [
        .target(name: "RelayDockCore"),
        .executableTarget(name: "RelayDock", dependencies: ["RelayDockCore"]),
        .testTarget(name: "RelayDockCoreTests", dependencies: ["RelayDockCore"]),
    ]
)
