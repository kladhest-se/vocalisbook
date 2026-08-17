import Foundation
import Testing
@testable import Platform

@Suite("Window sizing")
struct WindowSizerTests {

    /// The threshold decides which layout is drawn, and both sizes have to sit
    /// on the correct side of it — a mini size wider than `compactWidth` would
    /// shrink the window and still show the library.
    @Test("The two sizes fall on the intended sides of the threshold")
    func sizesStraddleTheThreshold() {
        #expect(WindowSizer.miniSize.width < WindowSizer.compactWidth)
        #expect(WindowSizer.regularSize.width >= WindowSizer.compactWidth)
    }

    @Test("The mini player is tall enough to hold its controls")
    func miniIsUsable() {
        #expect(WindowSizer.miniSize.height >= 480)
    }
}
