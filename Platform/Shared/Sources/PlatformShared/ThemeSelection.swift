import SwiftUI

/// What the one theme control offers.
///
/// A single list rather than a mode and a theme. Two controls meant deciding
/// twice, and the second one was meaningless in one of the modes — so it sat
/// there enabled and irrelevant. The automatic behaviours are simply the first
/// two entries in the same list.
public enum ThemeSelection: Hashable, Sendable {
    /// Light or dark, following the system.
    case matchSystem
    /// Nocturne after dark, a light theme before it.
    case nightAfterDark
    /// One theme, always.
    case fixed(Theme)

    public static var all: [ThemeSelection] {
        [.matchSystem, .nightAfterDark] + Theme.allCases.map(ThemeSelection.fixed)
    }

    public var title: String {
        switch self {
        case .matchSystem: "Match system"
        case .nightAfterDark: "Night mode after dark"
        case .fixed(let theme): theme.title
        }
    }

    public var subtitle: String {
        switch self {
        case .matchSystem:
            "Light by day, dark by night"
        case .nightAfterDark:
            "Nocturne after 20:00 — near-black, warm, no blue"
        case .fixed(let theme):
            theme.subtitle
        }
    }

    /// The theme to draw a swatch with. The automatic entries preview what they
    /// will most often look like rather than showing nothing.
    public var previewTheme: Theme {
        switch self {
        case .matchSystem: .systemDark
        case .nightAfterDark: .nocturne
        case .fixed(let theme): theme
        }
    }

    // MARK: - Storage

    /// Stored as one string, so there is one thing to read and one to write.
    public var storageKey: String {
        switch self {
        case .matchSystem: "system"
        case .nightAfterDark: "night"
        case .fixed(let theme): theme.rawValue
        }
    }

    public init?(storageKey: String) {
        switch storageKey {
        case "system": self = .matchSystem
        case "night": self = .nightAfterDark
        default:
            guard let theme = Theme(rawValue: storageKey) else { return nil }
            self = .fixed(theme)
        }
    }
}
