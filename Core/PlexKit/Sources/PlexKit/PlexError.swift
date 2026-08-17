import Foundation

public enum PlexError: Error, Sendable, Equatable {
    /// Transport failed before an HTTP response was produced.
    case transport(String)
    /// Server answered, but with a status we cannot use.
    case http(status: Int, body: String?)
    /// Token was rejected. Callers must treat this as *degraded*, not as
    /// "signed out" — downloaded content stays playable and the outbox keeps
    /// accumulating until the user actually re-authenticates.
    case unauthorized
    /// Response body did not match the expected shape.
    case decoding(String)
    /// PIN was never claimed inside the allotted window.
    case authorizationTimedOut
    /// No connection candidate answered `/identity` in time.
    case noReachableConnection
    case cancelled

    public var isAuthFailure: Bool {
        switch self {
        case .unauthorized: true
        case .http(let status, _): status == 401 || status == 403
        default: false
        }
    }

    /// True when retrying later is plausibly useful.
    public var isTransient: Bool {
        switch self {
        case .transport, .noReachableConnection: true
        case .http(let status, _): status >= 500 || status == 429
        default: false
        }
    }
}

/// Readable messages.
///
/// Without this, `error.localizedDescription` on a plain Swift error produces
/// "The operation couldn't be completed. (PlexKit.PlexError error 0.)" — the
/// enum's case *index*, which tells a person nothing and a developer only
/// slightly more. That string was the entire diagnosis available when the macOS
/// app could not sign in.
///
/// Each case says what failed and, where there is one, what to do about it. The
/// underlying detail is included rather than swallowed: a transport failure's
/// message is usually the whole answer.
extension PlexError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transport(let detail):
            "Could not reach Plex: \(detail)"
        case .http(let status, let body):
            if let body, !body.isEmpty {
                "Plex answered \(status): \(body)"
            } else {
                "Plex answered \(status)."
            }
        case .unauthorized:
            "Plex rejected this device's token. Signing in again will issue a new one."
        case .decoding(let detail):
            "Plex sent something unexpected: \(detail)"
        case .authorizationTimedOut:
            "The sign-in request expired before it was approved."
        case .noReachableConnection:
            "None of the addresses Plex advertises for this server answered."
        case .cancelled:
            "Cancelled."
        }
    }

    public var failureReason: String? {
        switch self {
        case .transport:
            "The request never reached a server. On macOS this is usually the App "
            + "Sandbox: an app with ENABLE_APP_SANDBOX and no outgoing-network "
            + "permission cannot open a socket at all."
        case .noReachableConnection:
            "Every candidate was tried in turn — local first, then direct, then "
            + "relay. On iPhone and Apple TV the usual cause is local network "
            + "permission: a server on your own LAN is unreachable until it is "
            + "granted, and the request is refused before it leaves the device. "
            + "Settings, then this app, then Local Network."
        default:
            nil
        }
    }
}

extension Error {
    /// What went wrong, and — when the error knows one — why.
    ///
    /// `localizedDescription` returns only `errorDescription`, so a
    /// `failureReason` is written and never seen. Both reasons in this file are
    /// the useful half: one names the App Sandbox as the cause of a request that
    /// never left a Mac, the other names local network permission as the cause
    /// of a LAN server that cannot be reached from a phone. Neither is guessable
    /// from "none of the addresses answered".
    ///
    /// On `Error` rather than `PlexError` so a call site can use it without
    /// knowing which kind of error it caught, which is the situation every catch
    /// block here is in.
    public var plexExplanation: String {
        let description = localizedDescription
        guard let reason = (self as? LocalizedError)?.failureReason else { return description }
        return "\(description)\n\n\(reason)"
    }
}
