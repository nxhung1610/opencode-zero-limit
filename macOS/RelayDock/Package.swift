// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelayDock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RelayDock", targets: ["RelayDockApp"]),
        .executable(name: "RelayDockLauncher", targets: ["RelayDockLauncher"]),
        .executable(name: "RelayDockEdge", targets: ["RelayDockEdge"]),
        .library(name: "RelayDockCore", targets: ["RelayDockCore"]),
    ],
    targets: [
        .target(name: "RelayDockCore"),
        .executableTarget(
            name: "RelayDockApp",
            dependencies: ["RelayDockCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "RelayDockLauncher", dependencies: ["RelayDockCore"]),
        .executableTarget(name: "RelayDockEdge", dependencies: ["RelayDockCore"]),
        .testTarget(name: "RelayDockCoreTests", dependencies: ["RelayDockCore"]),
        .testTarget(name: "RelayDockAppTests", dependencies: ["RelayDockApp", "RelayDockCore"]),
        .testTarget(name: "RelayDockLauncherTests", dependencies: ["RelayDockLauncher", "RelayDockCore"]),
        .testTarget(name: "RelayDockEdgeTests", dependencies: ["RelayDockEdge", "RelayDockCore"]),
    ]
)
