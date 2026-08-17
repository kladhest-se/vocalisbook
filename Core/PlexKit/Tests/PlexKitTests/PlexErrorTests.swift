import Foundation
import Testing
@testable import PlexKit

/// The half of an error that was written and never shown.
///
/// `localizedDescription` returns only `errorDescription`, so both
/// `failureReason`s in `PlexError` — the two that name a *cause* rather than a
/// symptom — reached no screen at all.
@Suite("Error explanations")
struct PlexErrorTests {

    /// The symptom is "no address answered". The cause, on a phone, is usually
    /// that iOS refused the request before it left the device — and nothing
    /// about the symptom leads anybody to Settings.
    @Test("An unreachable server explains local network permission")
    func unreachableNamesLocalNetwork() {
        let explanation = PlexError.noReachableConnection.plexExplanation

        #expect(explanation.contains("Local Network"))
        // And still says what happened, not only why.
        #expect(explanation.contains("addresses"))
    }

    /// The Mac's version of the same shape: a request that never left the
    /// process, because the sandbox would not open a socket.
    @Test("A transport failure explains the App Sandbox")
    func transportNamesTheSandbox() {
        let explanation = PlexError.transport("connection refused").plexExplanation
        #expect(explanation.contains("Sandbox"))
    }

    /// Most errors have no reason, and must not gain a blank line and a gap
    /// where one would go.
    @Test("An error with no reason is unchanged")
    func noReasonIsJustTheDescription() {
        let explanation = PlexError.authorizationTimedOut.plexExplanation

        #expect(explanation == PlexError.authorizationTimedOut.localizedDescription)
        #expect(!explanation.contains("\n"))
    }

    /// It is on `Error`, so a catch block can use it without knowing what it
    /// caught — which is the situation every catch block in the apps is in.
    @Test("Any error can be explained, not only a Plex one")
    func worksOnAnyError() {
        struct Whatever: Error {}
        let explanation = (Whatever() as Error).plexExplanation

        #expect(!explanation.isEmpty)
    }
}
