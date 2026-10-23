// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OtterClip",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClipCore", targets: ["ClipCore"]),
        .executable(name: "OtterClip", targets: ["OtterClip"])
    ],
    targets: [
        .target(name: "ClipCore"),
        .executableTarget(name: "OtterClip", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"])
    ]
)
