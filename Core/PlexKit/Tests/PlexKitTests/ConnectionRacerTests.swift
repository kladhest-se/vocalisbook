import Foundation
import Testing
@testable import PlexKit

@Suite("Connection racing")
struct ConnectionRacerTests {

    private func resource(connections: [[String: Any]]) throws -> PlexResource {
        let payload: [String: Any] = [
            "clientIdentifier": "SERVER-MACHINE-ID",
            "name": "sth-ts-pms001",
            "provides": "server",
            "owned": true,
            "accessToken": "srv_token",
            "connections": connections,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try PlexTransport.decoder.decode(PlexResource.self, from: data)
    }

    private let identityBody = #"{"MediaContainer":{"machineIdentifier":"SERVER-MACHINE-ID","version":"1.41.0"}}"#

    @Test("A reachable LAN address wins over a reachable relay")
    func lanBeatsRelay() async throws {
        let resource = try resource(connections: [
            ["uri": "https://relay.plex.direct:443", "local": false, "relay": true, "IPv6": false],
            ["uri": "https://lan.plex.direct:32400", "local": true, "relay": false, "IPv6": false],
        ])

        let stub = StubHTTPClient()
        stub.on(pathContains: "identity") { _ in
            HTTPResponse(status: 200, body: Data(#"{"machineIdentifier":"SERVER-MACHINE-ID"}"#.utf8))
        }

        let resolved = try await ConnectionRacer(client: stub, identity: .test)
            .resolve(resource, fallbackToken: "account_token")

        #expect(resolved.isLocal)
        #expect(resolved.isRelay == false)
        #expect(resolved.baseURL.absoluteString.contains("lan.plex.direct"))
        // The relay tier must never have been probed at all.
        #expect(stub.requests(containing: "relay.plex.direct").isEmpty)
    }

    @Test("Falls through to the relay when the LAN tier is unreachable")
    func fallsThroughTiers() async throws {
        let resource = try resource(connections: [
            ["uri": "https://lan.plex.direct:32400", "local": true, "relay": false, "IPv6": false],
            ["uri": "https://relay.plex.direct:443", "local": false, "relay": true, "IPv6": false],
        ])

        let stub = StubHTTPClient()
        stub.on(pathContains: "lan.plex.direct") { _ in HTTPResponse(status: 500, body: Data()) }
        stub.on(pathContains: "relay.plex.direct") { _ in
            HTTPResponse(status: 200, body: Data(#"{"machineIdentifier":"SERVER-MACHINE-ID"}"#.utf8))
        }

        let resolved = try await ConnectionRacer(client: stub, identity: .test)
            .resolve(resource, fallbackToken: "account_token")

        #expect(resolved.isRelay)
    }

    @Test("A 200 from the wrong machine is rejected, not accepted")
    func rejectsImpostor() async throws {
        let resource = try resource(connections: [
            ["uri": "https://captive.example.com", "local": true, "relay": false, "IPv6": false],
        ])

        let stub = StubHTTPClient()
        stub.on(pathContains: "captive.example.com") { _ in
            HTTPResponse(status: 200, body: Data(#"{"machineIdentifier":"SOMEONE-ELSE"}"#.utf8))
        }

        await #expect(throws: PlexError.noReachableConnection) {
            try await ConnectionRacer(client: stub, identity: .test)
                .resolve(resource, fallbackToken: "account_token")
        }
    }

    @Test("The server access token is preferred over the account token")
    func prefersServerToken() async throws {
        let resource = try resource(connections: [
            ["uri": "https://lan.plex.direct:32400", "local": true, "relay": false, "IPv6": false],
        ])
        let stub = StubHTTPClient()
        stub.on(pathContains: "identity") { _ in
            HTTPResponse(status: 200, body: Data(#"{"machineIdentifier":"SERVER-MACHINE-ID"}"#.utf8))
        }

        let resolved = try await ConnectionRacer(client: stub, identity: .test)
            .resolve(resource, fallbackToken: "account_token")
        #expect(resolved.accessToken == "srv_token")
    }
}
