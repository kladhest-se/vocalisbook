import Foundation

/// Implements the plex.tv PIN flow.
///
/// The authorisation page must be shown by something running *out of process* —
/// `ASWebAuthenticationSession` on iOS and macOS — never a `WKWebView`. An
/// in-app view would let this client read the credentials being typed, which is
/// exactly what the PIN flow exists to prevent.
///
/// `openURL` into Safari satisfies that too, and was the first approach here,
/// but it cannot be undone: after approval the page sits there reading "you may
/// now close this window" and no application can dismiss another's window. A
/// session presented by the app can be cancelled the moment `waitForToken`
/// returns, which is what the ports do.
///
/// tvOS has no browser at all — see `authorizationURL(for:)` for the code-entry
/// variant that screen should present instead.
public struct PlexPinAuthenticator: Sendable {
    private let transport: PlexTransport
    private let identity: PlexClientIdentity
    private let baseURL: URL

    public init(
        transport: PlexTransport,
        identity: PlexClientIdentity,
        baseURL: URL = URL(string: "https://plex.tv")!
    ) {
        self.transport = transport
        self.identity = identity
        self.baseURL = baseURL
    }

    /// Requests a fresh PIN.
    ///
    /// The two kinds are not interchangeable, and an earlier comment here had it
    /// exactly backwards:
    ///
    /// - `strong: true` returns a long opaque code, meant to travel inside the
    ///   `app.plex.tv/auth` URL where nobody ever reads it. Use it whenever a
    ///   browser carries the code for you.
    /// - `strong: false` returns the short code that plex.tv/link accepts. Use
    ///   it whenever a person has to read the code off a screen and type it
    ///   somewhere else.
    ///
    /// The tvOS app asked for a strong one and put twenty-odd characters on a
    /// television for someone to copy by hand. It works, in the sense that the
    /// flow completes; it is simply the wrong code for that screen.
    public func requestPin(strong: Bool = true) async throws -> PlexPin {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v2/pins"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "strong", value: strong ? "true" : "false")]

        let request = HTTPRequest(method: .post, url: components.url!)
        return try await transport.decode(PlexPin.self, from: request)
    }

    /// The URL to open in the system browser. On tvOS, display
    /// `pin.code` on screen and tell the user to visit `plex.tv/link`
    /// instead — a TV cannot present this page.
    public func authorizationURL(for pin: PlexPin) -> URL {
        var components = URLComponents(string: "https://app.plex.tv/auth")!
        let fragment = [
            URLQueryItem(name: "clientID", value: identity.clientIdentifier),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: identity.product),
            URLQueryItem(name: "context[device][deviceName]", value: identity.deviceName),
            URLQueryItem(name: "context[device][platform]", value: identity.platform),
        ]
        var fragmentComponents = URLComponents()
        fragmentComponents.queryItems = fragment
        components.fragment = "?" + (fragmentComponents.percentEncodedQuery ?? "")
        return components.url!
    }

    /// Polls until the PIN is claimed or the deadline passes.
    ///
    /// Plex rate-limits this endpoint, so the interval is deliberately not
    /// tightened below a second. Cancellation propagates — the sign-in screen
    /// cancels this task when the user backs out.
    public func waitForToken(
        pin: PlexPin,
        pollInterval: Duration = .seconds(2),
        timeout: Duration = .seconds(300)
    ) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let url = baseURL.appendingPathComponent("api/v2/pins/\(pin.id)")

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            let polled = try await transport.decode(
                PlexPin.self,
                from: HTTPRequest(url: url)
            )
            if let token = polled.authToken, !token.isEmpty {
                return token
            }
            if let expiry = polled.expiresAt, expiry < Date() {
                throw PlexError.authorizationTimedOut
            }
            try await Task.sleep(for: pollInterval)
        }
        throw PlexError.authorizationTimedOut
    }

    /// Best-effort session invalidation. Failure here is not worth surfacing —
    /// the local token is discarded either way.
    public func signOut(token: String) async {
        let url = baseURL.appendingPathComponent("api/v2/users/signout")
        _ = try? await transport.send(HTTPRequest(method: .delete, url: url), token: token)
    }
}
