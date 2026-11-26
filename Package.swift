// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Timbre",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Timbre",
            path: "Sources/Timbre",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
