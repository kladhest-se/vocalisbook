import UIKit

/// The four app icons the pack ships.
///
/// Alternate icons are an iOS feature. tvOS has no equivalent — `setAlternateIconName`
/// simply does not exist there, because a tvOS icon is a layered image stack the
/// system parallaxes and it cannot be swapped at runtime. The tvOS app therefore
/// ships the amber icon and has no picker, rather than a control that would do
/// nothing.
public enum AppIcon: String, CaseIterable, Sendable {
    case amber
    case ocean
    case ruby
    case teal

    public var title: String {
        switch self {
        case .amber: "Amber"
        case .ocean: "Ocean"
        case .ruby: "Ruby"
        case .teal: "Teal"
        }
    }

    /// What `setAlternateIconName` wants: nil for the primary icon, the asset
    /// name for the rest. The names must match
    /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in Config/iOS.xcconfig.
    public var alternateName: String? {
        switch self {
        case .amber: nil
        case .ocean: "AppIcon-Ocean"
        case .ruby: "AppIcon-Ruby"
        case .teal: "AppIcon-Teal"
        }
    }

    /// The asset to draw in a picker. The primary icon is not reachable by name
    /// from the catalog at runtime, so every variant also exists as a plain
    /// image the picker can show.
    public var previewAssetName: String {
        "AppIcon-Preview-\(rawValue)"
    }
}

@MainActor
public enum AppIconStore {

    public static var current: AppIcon {
        let name = UIApplication.shared.alternateIconName
        return AppIcon.allCases.first { $0.alternateName == name } ?? .amber
    }

    public static var isSupported: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    /// Whether a failure here is the Simulator rather than the app.
    ///
    /// `setAlternateIconName` fails on the Simulator far more often than not,
    /// with `NSCocoaErrorDomain` 4 or a bare POSIX `EIO` — "The operation
    /// couldn't be completed. Input/output error". It is a long-standing
    /// Simulator limitation and says nothing about whether the icons are
    /// correctly declared; the same build works on a device.
    ///
    /// Worth naming rather than passing the raw string to the user, because that
    /// string reads as data loss and sends you looking at the asset catalog,
    /// which is where the next hour goes.
    public static var alternateIconsAreUnreliableHere: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Applies an icon.
    ///
    /// iOS posts a system alert saying the icon changed, which cannot be
    /// suppressed and is not worth fighting. Failure is reported rather than
    /// swallowed: on a device the usual cause is a name that does not match the
    /// build setting, and silently keeping the old icon makes that look like the
    /// picker is broken.
    public static func set(_ icon: AppIcon) async throws {
        guard UIApplication.shared.supportsAlternateIcons else {
            throw AppIconError.unsupported
        }
        guard icon.alternateName != UIApplication.shared.alternateIconName else { return }

        do {
            try await UIApplication.shared.setAlternateIconName(icon.alternateName)
        } catch {
            throw AppIconError.failed(
                underlying: error,
                onSimulator: alternateIconsAreUnreliableHere
            )
        }
    }
}

public enum AppIconError: LocalizedError {
    case unsupported
    case failed(underlying: any Error, onSimulator: Bool)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            "This device does not allow the app icon to be changed."
        case .failed(let underlying, let onSimulator):
            onSimulator
                ? "The Simulator usually refuses to change the app icon. Try it on a device."
                : underlying.localizedDescription
        }
    }
}
