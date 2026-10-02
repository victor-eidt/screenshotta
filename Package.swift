// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScreenOtter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenOtter",
            path: "Sources/ScreenOtter",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ScreenOtterTests",
            dependencies: ["ScreenOtter"],
            path: "Tests/ScreenOtterTests",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
