import Foundation

/// What this platform can actually do.
///
/// Each of the three repos declares its own version of this type. Feature code
/// branches on these rather than on `#if os(...)`, so a screen that is wrong
/// for a platform fails to compile there instead of shipping a dead button.
public enum PlatformCapabilities {
    /// iOS has a real Documents directory and a background URLSession.
    public static let supportsOfflineDownloads = true

    /// The local database is authoritative and survives relaunch.
    public static let localStoreIsDurable = true

    /// Sign-in opens app.plex.tv in the system browser.
    public static let supportsBrowserSignIn = true

    // No `supportsCarPlay` here, deliberately.
    //
    // It said true for as long as the flag existed, with no CarPlay anywhere in
    // the repository. Nothing read it, so nothing broke — but a capability list
    // describes what a port can do, and an entry describing an intention is the
    // one kind of entry it must not contain.
    //
    // Setting it false would have been a flag nobody reads about a feature
    // nobody has. CarPlay is out of the first release; when it arrives, the flag
    // arrives with the code, and `capabilities.sh` will hold it to a
    // `CPTemplateApplicationSceneDelegate` on the way in.

    public static let supportsAudioSession = true

    /// Position may be flushed lazily — the local copy will still be here.
    public static let flushPositionEagerly = false

    /// AirPlay is offered as a route picker in the player.
    ///
    /// Routing itself needs nothing: the audio session already uses the
    /// long-form audio policy, which is what puts this app in the AirPlay 2
    /// audio group rather than mirroring a screen. What was missing was a way to
    /// choose the route without leaving for Control Centre.
    public static let supportsAirPlayPicker = true
}
