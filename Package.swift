// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpaceLens",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "SpaceLens",
            path: "Sources/SpaceLens",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SpaceLensTests",
            dependencies: ["SpaceLens"],
            path: "Tests/SpaceLensTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
