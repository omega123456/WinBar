// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WinBar",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "WinBar",
            path: "Sources/WinBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
