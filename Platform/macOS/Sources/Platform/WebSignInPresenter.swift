import AuthenticationServices
import Foundation
import AppKit

/// Presents the Plex authorisation page and, crucially, can close it again.
///
/// The first version opened `app.plex.tv` with `openURL`, which hands off to
/// Safari as a separate application. Sign-in worked, but the page then sat there
/// reading "you may now close this window" until the user tapped back manually —
/// no app can dismiss another app's window, and the Plex page cannot close
/// itself either. `ASWebAuthenticationSession` is presented *by* this app, so
/// `cancel()` dismisses it, and the PIN poll already knows the exact moment that
/// should happen.
///
/// This is still not an embedded web view. The session runs out of process, so
/// the app cannot read what is typed into it — which is the entire reason the
/// PIN flow exists and the reason a `WKWebView` would be the wrong answer no
/// matter how much tidier the dismissal was.
@MainActor
public final class WebSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {

    private var session: ASWebAuthenticationSession?

    /// Fires only when the *user* dismissed the page, not when this class did.
    /// Lets the caller stop polling for a PIN nobody is going to approve.
    public var onDismissedByUser: (() -> Void)?

    private var expectingOurOwnCancel = false

    public override init() { super.init() }

    public func present(_ url: URL) {
        cancel()
        expectingOurOwnCancel = false

        // No callback scheme: the Plex PIN flow does not redirect anywhere, so
        // there is nothing for the session to catch. Completion arrives only on
        // dismissal, and the token comes from polling instead.
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil,
            completionHandler: Self.completion(for: self)
        )
        session.presentationContextProvider = self
        // Share Safari's cookie jar, so an account already signed in on this
        // device is not asked for a password again. Ephemeral would be more
        // private and would mean typing the password on every sign-in.
        session.prefersEphemeralWebBrowserSession = false

        self.session = session
        session.start()
    }

    /// Closes the page because the PIN was claimed. This is the whole point.
    public func finish() {
        expectingOurOwnCancel = true
        session?.cancel()
        session = nil
    }

    /// Closes the page because the caller gave up.
    public func cancel() {
        expectingOurOwnCancel = true
        session?.cancel()
        session = nil
    }


    /// Builds the completion handler, deliberately outside this actor.
    ///
    /// `ASWebAuthenticationSession` keeps the handler and calls it when the
    /// session ends — from an XPC reply queue, not the main one. A closure
    /// written inside this `@MainActor` class is inferred to be MainActor
    /// isolated, so Swift checks that when AuthenticationServices calls it and
    /// traps:
    ///
    ///     _dispatch_assert_queue_fail
    ///     swift_task_isCurrentExecutorWithFlagsImpl
    ///     closure #1 in WebSignInPresenter.present(_:)
    ///     -[ASWebAuthenticationSession _endSessionWithCallbackURL:error:]
    ///
    /// which killed the macOS app the instant sign-in completed. Writing it in a
    /// `nonisolated` function makes the closure nonisolated too, and it hops to
    /// the main actor itself to touch anything here.
    ///
    /// Third time in this project: AVPlayer KVO, `MPMediaItemArtwork`, and now
    /// this. `tests/contract.sh` covers all three constructors.
    private nonisolated static func completion(
        for presenter: WebSignInPresenter
    ) -> @Sendable (URL?, Error?) -> Void {
        { [weak presenter] _, _ in
            Task { @MainActor in presenter?.sessionEnded() }
        }
    }

    /// The session closed, for whatever reason.
    private func sessionEnded() {
        session = nil
        if !expectingOurOwnCancel {
            onDismissedByUser?()
        }
    }

    public nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        // MAIN-QUEUE: ASWebAuthenticationSession calls its presentation context
        // provider on the main thread — it is a UI callback and there is no
        // queue argument to point at. Unlike AVPlayer's KVO, this one is
        // guaranteed by the framework.
        MainActor.assumeIsolated {
            // The fallback is never expected to be used — a sign-in screen is on
            // screen by definition — but returning a detached window is better
            // than trapping in a code path nobody can reproduce.
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        }
    }
}
