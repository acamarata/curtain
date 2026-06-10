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
        .executableTarget(
            name: "Curtain",
            dependencies: ["CurtainShared"],
            path: "Sources/Curtain"
        ),
        .executableTarget(
            name: "CurtainHelper",
            dependencies: ["CurtainShared"],
            path: "Sources/CurtainHelper"
        ),
        .testTarget(
            name: "CurtainSharedTests",
            dependencies: ["CurtainShared"],
            path: "Tests/CurtainSharedTests"
        )
    ]
)
