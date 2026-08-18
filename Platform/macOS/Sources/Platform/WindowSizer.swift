import AppKit

/// Resizes the main window between the two layouts.
///
/// The layout itself follows the window width — there is no mode to remember and
/// no toggle to get stuck in the wrong state. These only move the window; what
/// gets drawn is decided by measuring it.
@MainActor
public enum WindowSizer {

    /// Below this the window shows the compact player instead of the library.
    ///
    /// Chosen for the point where a cover grid stops being browsable and the
    /// docked transport bar runs out of room for its labels, not for any
    /// particular device.
    // `nonisolated`, like the two sizes below.
    //
    // This type is `@MainActor` because it moves an `NSWindow`. These three are
    // numbers, and inheriting the isolation made them unreadable from anywhere
    // else — including a test, which is a nonisolated context and could not
    // reference them at all. A constant that cannot be read outside the main
    // actor is isolated by accident rather than by design.
    nonisolated public static let compactWidth: CGFloat = 620

    /// Narrow enough for the compact player, and no narrower than its controls.
    nonisolated public static let miniSize = NSSize(width: 380, height: 720)

    nonisolated public static let regularSize = NSSize(width: 1100, height: 700)

    /// The floor `applyChrome` sets directly on the window, in each mode.
    ///
    /// `RootView`'s `.windowResizability(.contentSize)` is meant to derive
    /// this from content on its own, and normally would — but whether it
    /// recomputes reactively as the active branch switches between
    /// `CompactPlayerView` and `LibraryView`, rather than only once, is not
    /// something this app controls or can fully rely on. Setting `NSWindow`'s
    /// own `minSize` here as well costs nothing when the SwiftUI side is
    /// already right, and is the one thing guaranteed to work if it is not.
    /// The compact floor sits under the ultra-minimal player's own 260pt
    /// height threshold, so there is room to drag into that state rather than
    /// the window stopping right at its edge; the library floor sits above
    /// `compactWidth`, so it is never asked to hold a sidebar and a grid at a
    /// size neither has room for.
    nonisolated private static let compactMinSize = NSSize(width: 140, height: 160)
    nonisolated private static let libraryMinSize = NSSize(width: 650, height: 450)

    private static var mainWindow: NSWindow? {
        // The settings window and the menu bar popover are also windows; the one
        // wanted here is the document-ish one that can actually resize.
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.resizable) }
    }

    public static func shrink() {
        resize(to: miniSize)
    }

    public static func expand() {
        resize(to: regularSize)
    }

    /// Opens at the library, whatever size it was closed at.
    ///
    /// AppKit restores the last window frame, and `defaultSize` only applies
    /// when there is nothing saved — so shrinking to the mini player once meant
    /// every later launch opened into it. The layout follows the window, so a
    /// restored 380pt frame is not a remembered *mode*, it is a remembered size
    /// that happens to mean one.
    ///
    /// Starting in the library is the right default because that is where you
    /// choose what to listen to; the mini player is somewhere you go afterwards.
    /// Deliberately only at launch — dragging the window narrow during a session
    /// still does what it always did.
    public static func expandOnLaunch() {
        guard let window = mainWindow else { return }
        if window.frame.width < compactWidth { expand() }
        applyChrome(compact: false)
    }

    /// Title bar off in the compact player, on in the library.
    ///
    /// A 380pt transport panel with a full title bar above it is mostly title
    /// bar. `fullSizeContentView` lets the content run to the top edge and keeps
    /// the window's rounded corners, which is the shape Plexamp uses and the one
    /// this layout was already imitating. The traffic lights stay — a window
    /// with no way to close it is a clever idea for about ten seconds.
    public static func applyChrome(compact: Bool) {
        guard let window = mainWindow else { return }
        window.titleVisibility = compact ? .hidden : .visible
        window.titlebarAppearsTransparent = compact
        window.isMovableByWindowBackground = compact
        if compact {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.minSize = compact ? compactMinSize : libraryMinSize

        // The traffic lights go too, in the small layout.
        //
        // Hiding the title and making the bar transparent left three buttons
        // floating over the artwork and a strip of empty chrome above it — which
        // is most of the height somebody shrank the window to save.
        //
        // Hidden rather than removed: `.closable` and friends stay in the style
        // mask, so ⌘W still closes and the window can still be zoomed from the
        // menu. Only the buttons are gone, and only while it is this small.
        for button in [NSWindow.ButtonType.closeButton,
                       .miniaturizeButton,
                       .zoomButton] {
            window.standardWindowButton(button)?.isHidden = compact
        }
    }

    /// `applyChrome`, but retried briefly if the window is not there yet.
    ///
    /// `applyChrome` no-ops silently when `mainWindow` finds nothing — right
    /// for a caller that only fires on a real resize, where the window is by
    /// definition already showing, and wrong for one that fires from a
    /// view's own appearance. AppKit's `isVisible` bookkeeping can lag a
    /// beat behind SwiftUI inserting that view into the hierarchy — closing
    /// the mini player and reopening it from the menu bar is exactly this: a
    /// new window, a new `CompactPlayerView`, and no guarantee about which of
    /// the two is ready first. A silent no-op in that gap is the empty title
    /// bar this exists to prevent. Five attempts, 50ms apart, catch it
    /// without costing anything once the window is already there — the
    /// common case returns after the first check.
    public static func applyChromeWhenReady(compact: Bool, attemptsRemaining: Int = 5) {
        guard mainWindow != nil else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                applyChromeWhenReady(compact: compact, attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }
        applyChrome(compact: compact)
    }

    /// Keeps the chrome in step with a window the user is dragging.
    ///
    /// The layout is decided by measuring, so the chrome has to be as well —
    /// otherwise dragging past the threshold changes what is drawn and leaves a
    /// title bar behind, or removes one from the library.
    public static func followResizes() {
        // The notification is deliberately unused.
        //
        // `Notification` is not Sendable, so it cannot cross into the main
        // actor — Swift 6 rejects `MainActor.assumeIsolated { ... note ... }`
        // with "sending 'note' risks causing data races". The usual answer is to
        // pull the needed values out first, as the audio session observers in
        // `AudiobookPlayer` do, but that does not work here: what this wants
        // from the notification is the `NSWindow`, and AppKit types are
        // main-actor isolated, so reading one outside the hop is the same fault
        // wearing a different hat.
        //
        // Nothing is lost by ignoring it. The question is only ever "how wide is
        // the main window now", which `mainWindow` answers directly.
        //
        // The comment lives here rather than inside the closure because
        // `contract.sh` looks back eight lines from an `assumeIsolated` for the
        // `queue: .main` that justifies it, and prose in between pushes it out
        // of view. Writing the explanation in the wrong place broke the check
        // that was about to be written to catch this very thing.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let window = mainWindow else { return }
                applyChrome(compact: window.frame.width < compactWidth)
            }
        }

        // And when a window appears, which is not a resize.
        //
        // Closing the mini player and reopening it from the menu bar makes a new
        // window: SwiftUI builds it at the remembered size, so the layout is the
        // small one, but nothing had resized — so the chrome was never applied
        // and the title bar came back with its traffic lights. Dragging the
        // window fixed it, which is the tell that only resizing was watched.
        //
        // The comment lives here rather than inside the closure because
        // `contract.sh` looks back eight lines from an `assumeIsolated` for the
        // `queue: .main` that justifies it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let window = mainWindow else { return }
                applyChrome(compact: window.frame.width < compactWidth)
            }
        }
    }

    public static func toggle() {
        guard let window = mainWindow else { return }
        window.frame.width < compactWidth ? expand() : shrink()
    }

    private static func resize(to size: NSSize) {
        guard let window = mainWindow else { return }
        var frame = window.frame
        // Keep the top-left corner where it is. Resizing from the origin makes
        // the window appear to jump up the screen, because AppKit frames grow
        // upward from the bottom-left.
        frame.origin.y += frame.size.height - size.height
        frame.size = size
        window.setFrame(frame, display: true, animate: true)
        applyChrome(compact: size.width < compactWidth)
    }
}
