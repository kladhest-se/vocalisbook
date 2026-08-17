// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlexKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "PlexKit", targets: ["PlexKit"]),
    ],
    targets: [
        .target(
            name: "PlexKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "PlexKitTests",
            dependencies: ["PlexKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
