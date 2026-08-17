import SwiftUI

/// The colour schemes.
///
/// Twelve of them, plus a night mode. An audiobook app is used in bed more than
/// anywhere else, so the dark end of this list matters more than the light end —
/// and "dark" for reading in the dark is not the same as "dark" for a bright
/// room. `nocturne` is the one meant for a dark bedroom: near-black ground, warm
/// dim accent, nothing above about 70% luminance anywhere.
///
/// Each theme is four colours and a scheme. That is deliberately few. A palette
/// with a dozen roles invites inconsistency, and everything on screen is either
/// the page, something raised off it, text, or the one thing being emphasised.
public enum Theme: String, CaseIterable, Sendable, Codable {
    case cream
    case sand
    case ember
    case ink
    case slate
    case forest
    case plum
    case nocturne

    // Catppuccin, all four flavours.
    //
    // Taken from the published palette rather than approximated: Base is the
    // page, Mantle is the raised surface, Text is text, and Mauve is the accent
    // in every flavour. Somebody who runs this palette in their terminal and
    // their editor will recognise it, and a near-miss would be worse than not
    // offering it.
    case latte
    case frappe
    case macchiato
    case mocha

    public var title: String {
        switch self {
        case .cream: "Cream"
        case .sand: "Sand"
        case .ember: "Ember"
        case .ink: "Ink"
        case .slate: "Slate"
        case .forest: "Forest"
        case .plum: "Plum"
        case .nocturne: "Nocturne"
        case .latte: "Latte"
        case .frappe: "Frappé"
        case .macchiato: "Macchiato"
        case .mocha: "Mocha"
        }
    }

    public var subtitle: String {
        switch self {
        case .cream: "Warm paper"
        case .sand: "Bright and neutral"
        case .ember: "Deep rust"
        case .ink: "Near black, amber accent"
        case .slate: "Cool grey"
        case .forest: "Deep green"
        case .plum: "Aubergine"
        case .nocturne: "Night mode — for reading in the dark"
        case .latte: "Catppuccin, light"
        case .frappe: "Catppuccin, soft dark"
        case .macchiato: "Catppuccin, dark"
        case .mocha: "Catppuccin, darkest"
        }
    }

    /// Whether this theme wants light or dark system controls.
    public var colorScheme: ColorScheme {
        switch self {
        case .cream, .sand, .latte: .light
        default: .dark
        }
    }

    /// The one meant for a dark room. Kept as a property rather than a
    /// hardcoded case at the call site so the answer lives with the palettes.
    public static var night: Theme { .nocturne }

    /// The pair used when following the system. Not configurable: the whole
    /// point of that mode is not having to choose.
    public static var systemLight: Theme { .cream }
    public static var systemDark: Theme { .plum }

    // MARK: - Palette

    /// The page.
    public var background: Color {
        switch self {
        case .cream:    Color(red: 0.96, green: 0.93, blue: 0.87)
        case .sand:     Color(red: 0.98, green: 0.97, blue: 0.94)
        case .ember:    Color(red: 0.44, green: 0.19, blue: 0.11)
        case .ink:      Color(red: 0.10, green: 0.07, blue: 0.06)
        case .slate:    Color(red: 0.11, green: 0.13, blue: 0.16)
        case .forest:   Color(red: 0.07, green: 0.13, blue: 0.10)
        case .plum:     Color(red: 0.14, green: 0.09, blue: 0.16)
        case .nocturne: Color(red: 0.04, green: 0.03, blue: 0.03)
        // Base.
        case .latte:      Color(red: 0.937, green: 0.945, blue: 0.960)
        case .frappe:     Color(red: 0.188, green: 0.204, blue: 0.267)
        case .macchiato:  Color(red: 0.141, green: 0.153, blue: 0.227)
        case .mocha:      Color(red: 0.118, green: 0.118, blue: 0.180)
        }
    }

    /// Cards, rows, anything raised off the page.
    public var surface: Color {
        switch self {
        case .cream:    Color(red: 0.93, green: 0.89, blue: 0.82)
        case .sand:     Color(red: 0.94, green: 0.92, blue: 0.88)
        case .ember:    Color(red: 0.38, green: 0.16, blue: 0.10)
        case .ink:      Color(red: 0.15, green: 0.12, blue: 0.10)
        case .slate:    Color(red: 0.16, green: 0.19, blue: 0.23)
        case .forest:   Color(red: 0.11, green: 0.18, blue: 0.14)
        case .plum:     Color(red: 0.20, green: 0.13, blue: 0.23)
        case .nocturne: Color(red: 0.08, green: 0.07, blue: 0.06)
        // Mantle.
        case .latte:      Color(red: 0.902, green: 0.914, blue: 0.937)
        case .frappe:     Color(red: 0.161, green: 0.176, blue: 0.231)
        case .macchiato:  Color(red: 0.118, green: 0.129, blue: 0.192)
        case .mocha:      Color(red: 0.094, green: 0.094, blue: 0.145)
        }
    }

    /// Body text.
    public var text: Color {
        switch self {
        case .cream:    Color(red: 0.13, green: 0.11, blue: 0.09)
        case .sand:     Color(red: 0.12, green: 0.12, blue: 0.12)
        case .ember:    Color(red: 0.98, green: 0.94, blue: 0.90)
        case .ink:      Color(red: 0.95, green: 0.92, blue: 0.88)
        case .slate:    Color(red: 0.92, green: 0.94, blue: 0.96)
        case .forest:   Color(red: 0.92, green: 0.95, blue: 0.92)
        case .plum:     Color(red: 0.95, green: 0.92, blue: 0.96)
        // Deliberately not white. Pure white on near-black at 3am is a torch.
        case .nocturne: Color(red: 0.72, green: 0.68, blue: 0.62)
        // Text.
        case .latte:      Color(red: 0.298, green: 0.310, blue: 0.412)
        case .frappe:     Color(red: 0.776, green: 0.816, blue: 0.961)
        case .macchiato:  Color(red: 0.792, green: 0.827, blue: 0.961)
        case .mocha:      Color(red: 0.804, green: 0.839, blue: 0.957)
        }
    }

    /// The one emphasised thing: play buttons, progress, the current chapter.
    public var accent: Color {
        switch self {
        case .cream:    Color(red: 0.78, green: 0.33, blue: 0.20)
        case .sand:     Color(red: 0.42, green: 0.45, blue: 0.24)
        case .ember:    Color(red: 0.91, green: 0.68, blue: 0.34)
        case .ink:      Color(red: 0.91, green: 0.68, blue: 0.34)
        case .slate:    Color(red: 0.44, green: 0.72, blue: 0.80)
        case .forest:   Color(red: 0.56, green: 0.76, blue: 0.44)
        case .plum:     Color(red: 0.85, green: 0.52, blue: 0.68)
        // Warm and dim: no blue at all, and low enough not to bloom.
        case .nocturne: Color(red: 0.72, green: 0.48, blue: 0.22)
        // Mauve, which is Catppuccin's own accent in each flavour.
        case .latte:      Color(red: 0.531, green: 0.400, blue: 0.933)
        case .frappe:     Color(red: 0.792, green: 0.620, blue: 0.902)
        case .macchiato:  Color(red: 0.788, green: 0.624, blue: 0.937)
        case .mocha:      Color(red: 0.796, green: 0.651, blue: 0.969)
        }
    }

    /// Text that is present but not the point.
    public var secondaryText: Color {
        text.opacity(0.62)
    }

    /// Text that is barely there — timestamps, counts, footnotes.
    public var tertiaryText: Color {
        text.opacity(0.40)
    }

    /// The unfilled part of a progress bar.
    public var track: Color {
        accent.opacity(colorScheme == .light ? 0.22 : 0.24)
    }
}
