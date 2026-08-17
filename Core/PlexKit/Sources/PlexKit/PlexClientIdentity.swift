import Foundation

/// Identifies this installation to plex.tv and to individual servers.
///
/// `clientIdentifier` must be stable for the lifetime of the installation. Plex
/// keys authorised devices off it, so regenerating it silently invalidates the
/// stored token and forces the user through sign-in again. Persist it in the
/// keychain on first launch and never derive it from anything the user can
/// change (device name, hostname, account email).
public struct PlexClientIdentity: Sendable, Hashable {
    public var clientIdentifier: String
    public var product: String
    public var version: String
    public var device: String
    public var deviceName: String
    public var platform: String
    public var platformVersion: String

    public init(
        clientIdentifier: String,
        product: String,
        version: String,
        device: String,
        deviceName: String,
        platform: String,
        platformVersion: String
    ) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.device = device
        self.deviceName = deviceName
        self.platform = platform
        self.platformVersion = platformVersion
    }

    /// Header set Plex expects on both plex.tv and server requests.
    public var headers: [String: String] {
        [
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Device": device,
            "X-Plex-Device-Name": deviceName,
            "X-Plex-Platform": platform,
            "X-Plex-Platform-Version": platformVersion,
            "Accept": "application/json",
        ]
    }
}
