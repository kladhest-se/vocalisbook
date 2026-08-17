// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Audiobooks",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10)],
    products: [.library(name: "Audiobooks", targets: ["Audiobooks"])],
    dependencies: [
        .package(path: "../PlexKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "Audiobooks",
            dependencies: [
                "PlexKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AudiobooksTests",
            // GRDB, because the migration tests drive `DatabaseMigrator`
            // directly: migrate to v1, put rows in, migrate up, check they are
            // still there. That is the sequence a real device performs, and
            // there is no way to express it through the stores — they describe
            // the schema as it is now.
            dependencies: [
                "Audiobooks",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
