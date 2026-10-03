// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WinBar",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Tests only (snapshot tests need XCTest, i.e. Xcode: run them with scripts/test.sh).
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.6"),
    ],
    targets: [
        .executableTarget(
            name: "WinBar",
            path: "Sources/WinBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WinBarTests",
            dependencies: ["WinBar", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            path: "Tests/WinBarTests",
            exclude: ["__Snapshots__"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
