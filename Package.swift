// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Peninsula",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Peninsula",
            path: "Sources/Peninsula",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
