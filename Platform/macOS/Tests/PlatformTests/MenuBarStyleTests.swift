import Foundation
import Testing
@testable import Platform

@Suite("Menu bar style")
struct MenuBarStyleTests {

    /// A name that is not in the catalog draws nothing — no error, no
    /// placeholder — which is how the menu bar item came to be present,
    /// clickable and invisible. `layout.sh` checks the catalog side; this checks
    /// that the names have not quietly changed.
    @Test("Each style names its own asset")
    func assetNames() {
        #expect(MenuBarStyle.monochrome.assetName == "MenuBarWhite")
        #expect(MenuBarStyle.colour.assetName == "MenuBarColor")
    }

    @Test("Every style has a distinct asset")
    func assetsAreDistinct() {
        let names = Set(MenuBarStyle.allCases.map(\.assetName))
        #expect(names.count == MenuBarStyle.allCases.count)
    }

    /// The raw values are what gets written to `UserDefaults`, so renaming a
    /// case silently resets everybody's preference.
    @Test("Raw values are stable")
    func rawValuesAreStable() {
        #expect(MenuBarStyle(rawValue: "monochrome") == .monochrome)
        #expect(MenuBarStyle(rawValue: "colour") == .colour)
    }
}
