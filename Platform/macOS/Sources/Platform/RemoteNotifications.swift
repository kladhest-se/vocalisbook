import AppKit

/// Asks the system for the silent pushes CloudKit sends.
///
/// `CKSyncEngine` learns that something changed on another device from a push.
/// Without this call none are delivered and the engine only finds out when it
/// next starts.
///
/// `NSApplication` rather than `UIApplication`, which is the whole difference
/// from the other two ports — and the reason this is three small files rather
/// than one in `PlatformShared`, which may not import either.
public enum RemoteNotifications {
    @MainActor
    public static func register() {
        NSApplication.shared.registerForRemoteNotifications()
    }

    /// Called when a silent push arrives.
    ///
    /// Set by the app at launch. The delegate receiving the push belongs to the
    /// platform layer and knows nothing about sync engines, so it calls this and
    /// the app decides what "something changed" means.
    @MainActor public static var onPush: (() async -> Void)?
}
