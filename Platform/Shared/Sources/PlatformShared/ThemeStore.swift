import SwiftUI

/// Which theme is in use.
///
/// One stored value and one control. The earlier version had a mode *and* a
/// theme, which meant two decisions for a setting most people touch once — and
/// in "match system" the theme picker did nothing at all while still being
/// enabled. `ThemeSelection` folds the automatic behaviours into the same list.
@MainActor
@Observable
public final class ThemeStore {

    private let defaults: UserDefaults

    public var selection: ThemeSelection {
        didSet { defaults.set(selection.storageKey, forKey: Key.selection) }
    }

    /// Set by the app from the environment and the clock.
    public var systemIsDark: Bool = false
    public var isAfterDark: Bool = false

    private enum Key {
        static let selection = "theme.selection"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Plum, so a fresh install opens on the theme the app is meant to look
        // like rather than whichever half of a pair the system happens to be in.
        self.selection = defaults.string(forKey: Key.selection)
            .flatMap(ThemeSelection.init(storageKey:)) ?? .fixed(.plum)
    }

    /// The theme to draw with right now.
    public var current: Theme {
        switch selection {
        case .matchSystem:
            systemIsDark ? Theme.systemDark : Theme.systemLight
        case .nightAfterDark:
            isAfterDark ? .night : Theme.systemLight
        case .fixed(let theme):
            theme
        }
    }
}

/// Reaches the current theme from any view.
public struct ThemeKey: EnvironmentKey {
    public static let defaultValue: Theme = .plum
}

extension EnvironmentValues {
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// Paints the page and hands the theme down.
    ///
    /// Applied once at the root rather than per screen: a theme that has to be
    /// remembered at every call site is a theme that will be forgotten at one.
    public func themed(_ theme: Theme) -> some View {
        // A colour behind everything, not a `.background`.
        //
        // `.background` sizes itself to the primary view, and adding
        // `.frame(maxWidth:.infinity, maxHeight:.infinity)` did not make that
        // primary view fill the screen — the app still sat in a band with black
        // above and below. A `Color` is greedy: as the first child of a ZStack it
        // takes all the space offered, the stack fills, and the content layers on
        // top. Nothing has to be persuaded to expand.
        ZStack {
            theme.background.ignoresSafeArea()
            self
        }
        .environment(\.theme, theme)
        .tint(theme.accent)
        .foregroundStyle(theme.text)
        .preferredColorScheme(theme.colorScheme)
    }
}
