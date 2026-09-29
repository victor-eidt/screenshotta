// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Screenshotta",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Screenshotta",
            path: "Sources/Screenshotta",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
