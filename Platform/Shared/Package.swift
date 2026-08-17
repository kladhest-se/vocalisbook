// swift-tools-version: 6.0
import PackageDescription

// The parts of the platform layer that are not platform-specific at all.
//
// Everything here must compile for every platform, which is why it declares all
// of them: no UIKit, no AppKit, no AVFoundation. Anything that needs a framework
// belongs in Platform/iOS, Platform/macOS or Platform/tvOS instead.
let package = Package(
    // The package name must match the directory.
    //
    // SwiftPM derives a package's *identity* from the last path component, and a
    // bare target dependency only resolves when identity, name and product line
    // up — which is why "PlexKit" and "Audiobooks" always worked. This was named
    // PlatformShared in a directory called Shared, so referring to it failed
    // with "product 'PlatformShared' ... not found. Did you mean
    // '.product(name: "shared_PlatformShared", package: "shared")'?".
    //
    // The product and module stay PlatformShared, which is what gets imported.
    name: "Shared",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10)],
    products: [.library(name: "PlatformShared", targets: ["PlatformShared"])],
    // Core, which is allowed: dependencies point downward, and PlexKit declares
    // the same platforms this does. Nothing here reaches sideways into a
    // Platform/<platform> package.
    // Audiobooks joined PlexKit when the CloudKit driver arrived. Same argument:
    // it is Core, dependencies point downward, and it declares the same four
    // platforms this does.
    //
    // It brings GRDB with it, which is the cost — this package's tests used to
    // build with nothing but PlexKit. Worth it because the alternative was three
    // copies of the driver, one per port, to avoid naming `CloudRecord` here.
    dependencies: [
        .package(path: "../../Core/PlexKit"),
        .package(path: "../../Core/Audiobooks"),
    ],
    targets: [
        .target(
            name: "PlatformShared",
            dependencies: ["PlexKit", "Audiobooks"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PlatformSharedTests",
            dependencies: ["PlatformShared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
