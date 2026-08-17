import Foundation

/// What this platform can actually do.
///
/// Each of the three repos declares its own version of this type. Feature code
/// branches on these rather than on `#if os(...)`, so a screen that is wrong
/// for a platform fails to compile there instead of shipping a dead button.
public enum PlatformCapabilities {
    /// tvOS gives an app no durable local storage: there is no usable Documents
    /// directory and Caches can be purged between launches. There is nowhere to
    /// put a 900 MB audiobook and no guarantee it would still be there. The TV
    /// is a streaming-only client, and this is a platform fact rather than an
    /// unimplemented feature.
    public static let supportsOfflineDownloads = false

    /// The local database is a rebuildable cache. It must be reconstructible
    /// from Plex plus CloudKit on every cold launch, and nothing may be read
    /// from it that is not also recoverable.
    public static let localStoreIsDurable = false

    /// A TV has no browser. Sign-in shows the PIN code and points the user at
    /// plex.tv/link on their phone while polling the same endpoint.
    public static let supportsBrowserSignIn = false

    public static let supportsAudioSession = true

    /// Because the local copy may not survive, position and bookmarks are
    /// pushed to CloudKit as soon as they change rather than on a timer.
    public static let flushPositionEagerly = true

    /// No route picker here.
    ///
    /// `AVRoutePickerView` does not exist on tvOS. Output is chosen by the
    /// system — holding the TV button on the Siri Remote opens the Control
    /// Centre panel that owns it — and a control in the app could only ever
    /// duplicate that badly. Not an unimplemented feature; there is nothing to
    /// implement.
    public static let supportsAirPlayPicker = false
}
