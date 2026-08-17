// swift-tools-version: 6.0
import PackageDescription

// The macOS half of the platform layer.
//
// Deliberately declares only its own platform: anything that would not compile
// for macOS fails here rather than at runtime on a device.
let package = Package(
    // The package name matches the directory.
    //
    // SwiftPM takes a package's *identity* from the last path component, so a
    // manifest named one thing in a folder called another cannot be referenced
    // from a sibling package. See Platform/Shared/Package.swift.
    //
    // The target and product are "Platform" regardless, so every app imports the
    // same module name whichever platform it is built for.
    name: "macOS",
    platforms: [.macOS(.v14)],
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
        // The first tests in the platform layer.
        //
        // This target was removed when the smart-rewind table moved to
        // Platform/Shared, with a note to add it back with the first test file.
        // This is that file.
        //
        // macOS is the only one of the three platform packages `swift test` can
        // run — `make platforms` builds iOS and tvOS against a generic simulator
        // destination with nothing booted, which cannot run a test. `drift.sh`
        // asserts the files under test are byte-identical across the copies, so
        // testing here covers all three.
        //
        // A test target whose directory is empty is not a harmless stub: SwiftPM
        // refuses to resolve the package graph at all, breaking every build that
        // depends on this and not merely the tests. `layout.sh` checks for that.
        .testTarget(
            name: "PlatformTests",
            dependencies: ["Platform"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
