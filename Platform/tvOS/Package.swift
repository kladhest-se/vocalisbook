// swift-tools-version: 6.0
import PackageDescription

// The tvOS half of the platform layer.
//
// Deliberately declares only its own platform: anything that would not compile
// for tvOS fails here rather than at runtime on a device.
let package = Package(
    // The package name matches the directory.
    //
    // SwiftPM takes a package's *identity* from the last path component, so a
    // manifest named one thing in a folder called another cannot be referenced
    // from a sibling package. See Platform/Shared/Package.swift.
    //
    // The target and product are "Platform" regardless, so every app imports the
    // same module name whichever platform it is built for.
    name: "tvOS",
    platforms: [.tvOS(.v17)],
    products: [.library(name: "Platform", targets: ["Platform"])],
    dependencies: [
        .package(path: "../../Core/PlexKit"),
        .package(path: "../../Core/Audiobooks"),
        .package(path: "../Shared"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "Platform",
            dependencies: [
                "PlexKit",
                "Audiobooks",
                .product(name: "PlatformShared", package: "Shared"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // No test target here yet.
        //
        // What was tested — the smart-rewind table — is platform-agnostic and
        // moved to Platform/Shared, which is where it belonged. Declaring a test
        // target whose directory is empty is not a harmless stub: SwiftPM
        // refuses to resolve the package graph at all, so it breaks every build
        // that depends on this, not just the tests. Add it back with the first
        // test file.
    ]
)
