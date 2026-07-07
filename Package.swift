// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PRWatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PRWatch",
            path: "Sources/PRWatch"
        ),
        .testTarget(
            name: "PRWatchTests",
            dependencies: ["PRWatch"],
            path: "Tests/PRWatchTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
