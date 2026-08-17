import AppKit
import os
import SwiftUI

/// How the menu bar item is drawn.
public enum MenuBarStyle: String, CaseIterable, Sendable, Codable {
    /// Rendered as a template, so the system tints it for a light or dark menu
    /// bar and it matches every other item up there.
    case monochrome
    /// The full-colour mark, left untinted.
    case colour

    public var assetName: String {
        switch self {
        case .monochrome: "MenuBarWhite"
        case .colour: "MenuBarColor"
        }
    }
}

/// Menu bar preferences.
///
/// The item is always present — there is no setting to hide it, because it is
/// what keeps the app reachable once the window is closed. Only its appearance
/// and whether closing the window quits are configurable.
@MainActor
@Observable
public final class MenuBarSettings {

    private let defaults: UserDefaults

    public var style: MenuBarStyle {
        didSet { defaults.set(style.rawValue, forKey: Key.style) }
    }

    /// Whether closing the window leaves the app running in the menu bar.
    ///
    /// On by default, and the reason the menu bar item exists: an audiobook
    /// playing while the window is shut is the ordinary case, not an edge one.
    public var staysResident: Bool {
        didSet { defaults.set(staysResident, forKey: Key.staysResident) }
    }

    /// Whether the window floats above other apps.
    ///
    /// For following along in a book while working in something else, which is
    /// what a small always-visible player is for. Applied immediately rather
    /// than at the next launch: a window preference you have to relaunch to see
    /// is one nobody believes worked.
    public var floatsAboveOtherApps: Bool {
        didSet {
            defaults.set(floatsAboveOtherApps, forKey: Key.floatsAboveOtherApps)
            Self.applyFloating(floatsAboveOtherApps)
        }
    }

    /// Puts every window at the floating level, or back to normal.
    ///
    /// Every window rather than the key one: the settings window is a window
    /// too, and raising only the frontmost would leave whichever happened to be
    /// in front floating for ever.
    @MainActor
    public static func applyFloating(_ floating: Bool) {
        for window in NSApp.windows where window.canBecomeMain {
            window.level = floating ? .floating : .normal
        }
    }

    private enum Key {
        static let style = "menuBar.style"
        static let staysResident = "menuBar.staysResident"
        static let floatsAboveOtherApps = "menuBar.floatsAboveOtherApps"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.style = defaults.string(forKey: Key.style)
            .flatMap(MenuBarStyle.init(rawValue:)) ?? .monochrome
        self.staysResident = defaults.object(forKey: Key.staysResident) as? Bool ?? true
        self.floatsAboveOtherApps = defaults.bool(forKey: Key.floatsAboveOtherApps)
    }
}

/// Keeps the app alive when its last window closes.
///
/// SwiftUI has no declarative equivalent — `applicationShouldTerminateAfterLastWindowClosed`
/// is the only way to answer this question, and it is asked of the delegate. The
/// answer is read from the same store the settings screen writes to, so the
/// toggle takes effect without a relaunch.
public final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by the app at launch.
    @MainActor public static var settings: MenuBarSettings?

    /// Opens into the library and keeps the window chrome in step with its size.
    ///
    /// Deferred by one turn of the run loop: SwiftUI creates the `WindowGroup`
    /// window as part of launching, and at the moment this is called there may
    /// be nothing to resize yet. `WindowSizer` no-ops on a missing window, so
    /// without the hop this silently does nothing — which is how it would have
    /// been "fixed" and shipped still broken.
    /// A silent push, handed to whoever is listening.
    ///
    /// The Mac already had a delegate, so this is one method rather than a new
    /// type — iOS and tvOS had none at all, and an app with no delegate is an
    /// app no push can reach however correct its entitlements are.
    // MAIN-QUEUE: AppKit calls its application delegate on the main thread.
    public func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        MainActor.assumeIsolated {
            guard let handler = RemoteNotifications.onPush else { return }
            Task { await handler() }
        }
    }

    /// Logged rather than ignored: this fired on every launch while the
    /// entitlement was missing, and nothing was listening.
    // MAIN-QUEUE: AppKit calls its application delegate on the main thread.
    public func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // `Logger`, not `print`: a print in a shipping app goes to a console
        // nobody is attached to, and this is the message that explains why sync
        // is running on its poll rather than on pushes.
        Logger(subsystem: "se.kladhest.vocalisbook", category: "push")
            .error("Push registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Before any window exists.
    ///
    /// `allowsAutomaticWindowTabbing` is read when a window is created, so
    /// setting it in `applicationDidFinishLaunching` — after SwiftUI has made
    /// the `WindowGroup`'s first window — changes nothing, which is why the tab
    /// bar was still there. `willFinishLaunching` runs before that.
    // MAIN-QUEUE: AppKit calls its application delegate on the main thread.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        // A `WindowGroup` allows more than one window, and AppKit then offers
        // automatic tabbing — a tab bar across the top of an app whose one
        // window holds a library, a player and a sidebar.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    // MAIN-QUEUE: AppKit calls its application delegate on the main thread.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                WindowSizer.expandOnLaunch()
                WindowSizer.followResizes()
                MenuTrimmer.removeUnusedMenus()

                // Restored here, not only when the toggle is used. The level is
                // a property of a window, and every launch makes new ones.
                if let settings = Self.settings, settings.floatsAboveOtherApps {
                    MenuBarSettings.applyFloating(true)
                }
            }
        }
    }

    /// Run before the process goes away, with the app waiting on it.
    ///
    /// Set by the app at launch, like `settings`. Quitting is the one moment a
    /// media client has to tell the server it has gone: without a final
    /// `stopped`, Plex's dashboard shows the session paused indefinitely,
    /// because nothing else ever tells it otherwise.
    ///
    /// It returns when the work is done or the deadline passes, whichever comes
    /// first — `applicationWillTerminate` blocks termination while it runs, so a
    /// request that hangs would hang the quit. One second is long enough for a
    /// request to a server on the same network and short enough that nobody
    /// notices if it is not.
    @MainActor public static var willTerminate: (@Sendable () async -> Void)?

    // MAIN-QUEUE: AppKit calls its application delegate on the main thread.
    public func applicationWillTerminate(_ notification: Notification) {
        let work = MainActor.assumeIsolated { Self.willTerminate }
        guard let work else { return }

        // A semaphore rather than a `Task` left to run: the process is going
        // away when this returns, and an unawaited task goes with it.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await work()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    // MAIN-QUEUE: AppKit calls its application delegate on the main thread. The
    // marker goes above the call because that is where contract.sh looks — a
    // justification written inside the closure is a justification the check
    // cannot see, which is how this failed its own rule first time.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            !(Self.settings?.staysResident ?? true)
        }
    }

    /// Clicking the Dock icon with no window open reopens one, which is what
    /// every other Mac app does and what people expect after closing to the
    /// menu bar.
    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

/// Takes the menus this app has nothing to put in.
///
/// SwiftUI builds File, Edit, View and Help whether or not anything fills them,
/// and offers no way to remove a whole menu — `CommandGroup(replacing:)` empties
/// a section, and an empty menu still opens to nothing. So this is AppKit,
/// after launch, once the menu bar exists.
///
/// The app has no documents, no text editing worth a menu, and no help book.
/// Four menus that open onto disabled items are four invitations to find out
/// there is nothing there.
///
/// By title, which means English. That is what the app is; when it is
/// localised this needs the localised titles or a different approach, and this
/// comment is where somebody will look.
@MainActor
public enum MenuTrimmer {
    public static func removeUnusedMenus() {
        guard let main = NSApp.mainMenu else { return }

        for title in ["File", "Edit", "View", "Help"] {
            guard let item = main.items.first(where: { $0.title == title }) else { continue }
            main.removeItem(item)
        }
    }
}
