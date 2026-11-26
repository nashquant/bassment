// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Bassment",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Bassment",
            path: "Sources/Bassment",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
