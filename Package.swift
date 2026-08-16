// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Curtain",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CurtainShared",
            path: "Sources/CurtainShared"
        ),
        .target(
            name: "CurtainCore",
            dependencies: ["CurtainShared"],
            path: "Sources/CurtainCore"
        ),
        .executableTarget(
            name: "Curtain",
            dependencies: ["CurtainShared", "CurtainCore"],
            path: "Sources/Curtain"
        ),
        .target(
            name: "CurtainHelperCore",
            dependencies: ["CurtainShared"],
            path: "Sources/CurtainHelperCore"
        ),
        .executableTarget(
            name: "CurtainHelper",
            dependencies: ["CurtainShared", "CurtainHelperCore"],
            path: "Sources/CurtainHelper"
        ),
        .testTarget(
            name: "CurtainSharedTests",
            dependencies: ["CurtainShared"],
            path: "Tests/CurtainSharedTests"
        ),
        .testTarget(
            name: "CurtainCoreTests",
            dependencies: ["CurtainCore"],
            path: "Tests/CurtainCoreTests"
        ),
        .testTarget(
            name: "CurtainHelperCoreTests",
            dependencies: ["CurtainHelperCore"],
            path: "Tests/CurtainHelperCoreTests"
        ),
        .testTarget(
            name: "CurtainTests",
            dependencies: ["CurtainShared", "CurtainCore", "Curtain"],
            path: "Tests/CurtainTests"
        )
    ]
)
