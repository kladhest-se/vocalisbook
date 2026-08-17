import Foundation
import Testing
@testable import PlexKit

/// What the server picker is given, and in what order.
///
/// The picker itself was rewritten recently — it now says only a server's name
/// and whose it is — and this is the thing that decides which servers reach it
/// at all. It had no tests.
@Suite("Resource directory")
struct ResourceDirectoryTests {

    private func directory(_ stub: StubHTTPClient) -> PlexResourceDirectory {
        PlexResourceDirectory(transport: PlexTransport(client: stub, identity: .test))
    }

    private func resource(
        _ name: String,
        id: String,
        owned: Bool = true,
        provides: String = "server"
    ) -> String {
        """
        {"clientIdentifier":"\(id)","name":"\(name)","provides":"\(provides)",
         "owned":\(owned),"connections":[]}
        """
    }

    /// The same endpoint lists every device on the account. A phone with Plex
    /// installed is a resource, and it is not somewhere to find audiobooks.
    @Test("Devices that are not servers are dropped")
    func onlyServers() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "resources", """
        [\(resource("sth-ts-pms001", id: "a")),
         \(resource("Tommy's iPhone", id: "b", provides: "client,player")),
         \(resource("A Plex Web client", id: "c", provides: "client"))]
        """)

        let servers = try await directory(stub).servers(token: "tok")

        #expect(servers.map(\.name) == ["sth-ts-pms001"])
    }

    /// A device can be several things at once, and one of them being a server is
    /// enough.
    @Test("A device that is both a server and a player still counts")
    func serverAmongOtherRoles() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "resources", """
        [\(resource("nas", id: "a", provides: "server,player,controller"))]
        """)

        let servers = try await directory(stub).servers(token: "tok")

        #expect(servers.count == 1)
    }

    /// Yours first. A shared server can be perfectly good and it is not the one
    /// somebody is looking for at the top of a list.
    @Test("Owned servers come before shared ones")
    func ownedFirst() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "resources", """
        [\(resource("anna-nas", id: "a", owned: false)),
         \(resource("zebra", id: "b", owned: true))]
        """)

        let servers = try await directory(stub).servers(token: "tok")

        #expect(servers.map(\.name) == ["zebra", "anna-nas"])
    }

    /// Within a group, by name — and case-insensitively, because a list that
    /// puts every capitalised name above every lowercase one looks broken rather
    /// than sorted.
    @Test("Within a group, by name, ignoring case")
    func nameOrderIgnoresCase() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "resources", """
        [\(resource("zebra", id: "a")),
         \(resource("Apple", id: "b")),
         \(resource("nas", id: "c"))]
        """)

        let servers = try await directory(stub).servers(token: "tok")

        #expect(servers.map(\.name) == ["Apple", "nas", "zebra"])
    }

    /// Without these the list omits half of what a homelab offers: no HTTPS
    /// addresses, no relay to fall back on, no IPv6.
    @Test("The request asks for https, relay and IPv6 addresses")
    func requestIncludesEverything() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "resources", "[]")

        _ = try await directory(stub).servers(token: "tok")

        let url = try #require(stub.recorded.first?.url.absoluteString)
        #expect(url.contains("includeHttps=1"))
        #expect(url.contains("includeRelay=1"))
        #expect(url.contains("includeIPv6=1"))
    }

    @Test("An account with no servers is an empty list, not a failure")
    func noServers() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "resources", "[]")

        let servers = try await directory(stub).servers(token: "tok")

        #expect(servers.isEmpty)
    }

    /// plex.tv still speaks XML to anyone who does not say otherwise, and an XML
    /// body decodes as nothing at all.
    @Test("The account request asks for JSON")
    func accountAsksForJSON() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "user", """
        {"id":1,"username":"tommy","title":"Tommy","email":"t@example.com"}
        """)

        _ = try await directory(stub).account(token: "tok")

        let request = try #require(stub.recorded.first)
        #expect(request.headers["Accept"] == "application/json")
    }
}
