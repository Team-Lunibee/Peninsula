// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dynamic",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dynamic",
            path: "Sources/Dynamic",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
