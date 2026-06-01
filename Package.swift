// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Curtain",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Curtain",
            path: "Sources/Curtain"
        )
    ]
)
