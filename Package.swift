// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shake",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShakeCore", targets: ["ShakeCore"]),
        .library(name: "ShakeUI", targets: ["ShakeUI"])
    ],
    dependencies: [],
    targets: [
        .target(name: "ZIPFoundation", dependencies: [], path: "Sources/ZIPFoundation"),
        .target(name: "ShakeCore", dependencies: ["ZIPFoundation"], path: "Sources/ShakeCore"),
        .target(name: "ShakeUI", dependencies: ["ShakeCore"], path: "Sources/ShakeUI"),
        .target(name: "ShakeMacAgent", dependencies: ["ShakeCore", "ShakeUI"],
                path: "Apps/macOS/Agent", exclude: ["AgentView.swift"]),
        .target(name: "ShakeMacLAN", dependencies: ["ShakeCore"], path: "Apps/macOS/LAN", exclude: ["LANReceiverView.swift"]),
        .testTarget(name: "ShakeMacAgentTests", dependencies: ["ShakeMacAgent", "ShakeMacLAN", "ShakeUI", "ShakeCore"]),
        .testTarget(name: "ShakeCoreTests", dependencies: ["ShakeCore"], path: "Tests/ShakeCoreTests")
    ]
)
