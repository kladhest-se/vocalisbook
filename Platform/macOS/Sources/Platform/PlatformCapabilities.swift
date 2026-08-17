import Foundation

/// What this platform can actually do.
///
/// Each of the three repos declares its own version of this type. Feature code
/// branches on these rather than on `#if os(...)`, so a screen that is wrong
/// for a platform fails to compile there instead of shipping a dead button.
public enum PlatformCapabilities {
    public static let supportsOfflineDownloads = true
    public static let localStoreIsDurable = true
    public static let supportsBrowserSignIn = true


    /// macOS has no AVAudioSession. Route and interruption handling go through
    /// `AVAudioEngine`/`MPRemoteCommandCenter` instead, and there is no ducking
    /// policy to configure.
    public static let supportsAudioSession = false

    public static let flushPositionEagerly = false

    /// AirPlay is offered as a route picker in the transport bar.
    ///
    /// `AVRoutePickerView` exists on macOS as an `NSView`, and routing works the
    /// same way it does on the phone.
    public static let supportsAirPlayPicker = true
}
