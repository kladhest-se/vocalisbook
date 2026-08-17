import Foundation

/// Who made this and which build you are looking at.
///
/// Read from the bundle rather than written here: the version and build come
/// from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, and a copy in Swift
/// would be a second place to forget to change.
///
/// In `PlatformShared` so all three ports show the same thing. They have
/// separate version numbers — they ship separately — but the same author, the
/// same project and the same link.
public enum AppIdentity: Sendable {
    public static let name = "VocalisBook"
    public static let author = "Tommy Frössman"
    public static let repository = URL(string: "https://github.com/kladhest-se/vocalisbook")!

    /// What the app is, in one sentence, for a window that has room for one.
    public static let summary = "A third-party audiobook player for Plex Media Server."

    /// The trademark notice, which is not the same as the summary and should not
    /// be folded into it.
    public static let disclaimer =
        "Not affiliated with Plex Inc. “Plex” is a trademark of Plex Inc."

    /// "0.1.0", from `MARKETING_VERSION`.
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// "42", from `CURRENT_PROJECT_VERSION` — the nth build of this port on the
    /// machine that built it.
    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// "0.1.0 (42)", which is how a version is written everywhere on Apple's
    /// platforms and therefore how somebody will read it back to you.
    public static var versionAndBuild: String { "\(version) (\(build))" }
}
