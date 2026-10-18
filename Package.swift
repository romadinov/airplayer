// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Airplayer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Airplayer",
            path: "Sources/Airplayer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
