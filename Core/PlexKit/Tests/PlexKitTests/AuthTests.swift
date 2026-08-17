import Foundation
import Testing
@testable import PlexKit

@Suite("PIN authorisation")
struct AuthTests {

    private func makeAuthenticator(_ stub: StubHTTPClient) -> PlexPinAuthenticator {
        PlexPinAuthenticator(
            transport: PlexTransport(client: stub, identity: .test),
            identity: .test
        )
    }

    @Test("Requesting a PIN sends the client identity headers")
    func requestPinSendsIdentity() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "/api/v2/pins", #"{"id":42,"code":"ABCD","authToken":null}"#)

        let pin = try await makeAuthenticator(stub).requestPin()
        #expect(pin.id == 42)
        #expect(pin.code == "ABCD")
        #expect(pin.isClaimed == false)

        let sent = try #require(stub.requests(containing: "pins").first)
        #expect(sent.method == .post)
        #expect(sent.headers["X-Plex-Client-Identifier"] == "TEST-CLIENT-0001")
        #expect(sent.headers["Accept"] == "application/json")
    }

    @Test("Polling returns the token once the PIN is claimed")
    func pollUntilClaimed() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "/api/v2/pins", #"{"id":42,"code":"ABCD","authToken":null}"#)
        let pin = try await makeAuthenticator(stub).requestPin()

        let claimed = StubHTTPClient()
        claimed.onJSON(pathContains: "/api/v2/pins/42", #"{"id":42,"code":"ABCD","authToken":"tok_live"}"#)

        let token = try await PlexPinAuthenticator(
            transport: PlexTransport(client: claimed, identity: .test),
            identity: .test
        ).waitForToken(pin: pin, pollInterval: .milliseconds(10), timeout: .seconds(2))

        #expect(token == "tok_live")
    }

    @Test("An unclaimed PIN eventually times out rather than polling forever")
    func pollTimesOut() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "/api/v2/pins", #"{"id":42,"code":"ABCD","authToken":null}"#)
        let authenticator = makeAuthenticator(stub)
        let pin = try await authenticator.requestPin()

        await #expect(throws: PlexError.authorizationTimedOut) {
            try await authenticator.waitForToken(
                pin: pin,
                pollInterval: .milliseconds(10),
                timeout: .milliseconds(120)
            )
        }
    }

    @Test("The authorisation URL carries the client id and code in the fragment")
    func authorizationURLShape() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "/api/v2/pins", #"{"id":42,"code":"ABCD"}"#)
        let authenticator = makeAuthenticator(stub)
        let pin = try await authenticator.requestPin()

        let url = authenticator.authorizationURL(for: pin).absoluteString
        #expect(url.hasPrefix("https://app.plex.tv/auth#?"))
        #expect(url.contains("clientID=TEST-CLIENT-0001"))
        #expect(url.contains("code=ABCD"))
    }
}
