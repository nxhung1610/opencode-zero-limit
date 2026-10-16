// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelayDock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RelayDock", targets: ["RelayDockApp"]),
        .library(name: "RelayDockCore", targets: ["RelayDockCore"]),
    ],
    targets: [
        .target(name: "RelayDockCore"),
        .executableTarget(name: "RelayDockApp", dependencies: ["RelayDockCore"]),
        .testTarget(name: "RelayDockCoreTests", dependencies: ["RelayDockCore"]),
        .testTarget(name: "RelayDockAppTests", dependencies: ["RelayDockApp", "RelayDockCore"]),
    ]
)
