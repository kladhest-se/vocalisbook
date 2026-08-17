import UIKit
import os

/// Asks the system for the silent pushes CloudKit sends.
///
/// `CKSyncEngine` learns that something changed on another device from a push.
/// Without this call none are delivered, and the engine only finds out when it
/// next starts — which is why a book played on the phone appeared on the
/// television after a relaunch and not before.
///
/// The `remote-notification` background mode in Info.plist is the other half:
/// the mode says the app *may* be woken by one, and this says it wants them.
/// Declaring the mode alone does nothing, which is easy to miss because the
/// system complains loudly about the missing mode and not at all about the
/// missing registration.
///
/// Nothing here presents a notification, so there is no permission to ask for
/// and no prompt: a silent push carries no alert, badge or sound, and
/// `UNUserNotificationCenter` is not involved.
public enum RemoteNotifications {
    @MainActor
    public static func register() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called when a silent push arrives, whatever asked for it.
    ///
    /// Set by the app at launch. The delegate that receives the push belongs to
    /// the platform layer and knows nothing about sync engines, so it calls this
    /// and the app decides what "something changed" means.
    ///
    /// Without a handler the entitlement and the registration achieve nothing:
    /// the push is delivered, the system waits to be told whether anything came
    /// of it, and the app returns `.noData` for a change it never fetched.
    @MainActor public static var onPush: (() async -> Void)?
}

/// Receives the pushes, because SwiftUI alone cannot.
///
/// `UIApplicationDelegateAdaptor` is the only route to
/// `didReceiveRemoteNotification` — a `App` has no equivalent, so an app with no
/// delegate is an app no silent push can reach however correct its entitlements
/// are.
public final class PushDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let handler = RemoteNotifications.onPush else { return .noData }
        await handler()
        return .newData
    }

    /// Logged rather than ignored.
    ///
    /// This is what fired on every launch while the entitlement was missing, and
    /// nothing was listening — so the app looked like it had push and did not,
    /// and the poll quietly carried the whole feature.
    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // `Logger`, not `print`.
        //
        // A `print` in a shipping app goes to a console nobody is attached to.
        // This is the one message that explains why sync is running on its poll
        // instead of on pushes, and it is worth being readable in Console.app on
        // a device that is misbehaving rather than only in Xcode.
        //
        // The same subsystem `CloudSyncDriver` uses, so both halves of this
        // feature appear together when somebody filters for it.
        Logger(subsystem: "se.kladhest.vocalisbook", category: "push")
            .error("Push registration failed: \(error.localizedDescription, privacy: .public)")
    }
}
