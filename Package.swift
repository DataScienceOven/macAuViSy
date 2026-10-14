// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macAuViSy",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "PrivateToggles",
            path: "Sources/PrivateToggles"
        ),
        .executableTarget(
            name: "UnifiedControl",
            dependencies: ["PrivateToggles"],
            path: "Sources/UnifiedControl"
        )
    ]
)
