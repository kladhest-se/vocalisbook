import Foundation
import Testing
@testable import PlexKit

@Suite("Server client")
struct ServerClientTests {

    private func makeClient(_ stub: StubHTTPClient) -> PlexServerClient {
        let connection = ResolvedConnection(
            serverIdentifier: "SERVER-MACHINE-ID",
            baseURL: URL(string: "https://lan.plex.direct:32400")!,
            accessToken: "srv_token",
            isLocal: true,
            isRelay: false,
            resolvedAt: Date(),
            probeLatency: .milliseconds(4)
        )
        return PlexServerClient(
            connection: connection,
            transport: PlexTransport(client: stub, identity: .test)
        )
    }

    @Test("Tracks are ordered by tag index, not by the order Plex returned them")
    func tracksAreSorted() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "/children", """
        {"MediaContainer":{"size":3,"Metadata":[
          {"ratingKey":"3","title":"Chapter 3","index":3,"duration":600000},
          {"ratingKey":"1","title":"Chapter 1","index":1,"duration":600000},
          {"ratingKey":"2","title":"Chapter 2","index":2,"duration":600000}
        ]}}
        """)

        let tracks = try await makeClient(stub).tracks(bookRatingKey: "99")
        #expect(tracks.map(\.index) == [1, 2, 3])
    }

    @Test("Paging uses container headers rather than query parameters")
    func pagingHeaders() async throws {
        let stub = StubHTTPClient()
        stub.onJSON(pathContains: "/all", #"{"MediaContainer":{"size":0,"totalSize":900}}"#)

        _ = try await makeClient(stub).books(sectionKey: "2", offset: 400, limit: 200)
        let sent = try #require(stub.requests(containing: "/all").first)
        #expect(sent.headers["X-Plex-Container-Start"] == "400")
        #expect(sent.headers["X-Plex-Container-Size"] == "200")
        #expect(sent.headers["X-Plex-Token"] == "srv_token")
    }

    @Test("A rejected token surfaces as unauthorized, not as a generic HTTP error")
    func unauthorizedMapping() async throws {
        let stub = StubHTTPClient()
        stub.on(pathContains: "library/sections") { _ in
            HTTPResponse(status: 401, body: Data())
        }
        await #expect(throws: PlexError.unauthorized) {
            try await makeClient(stub).sections()
        }
    }

    @Test("Stream URLs carry the token in the query, as AVPlayer requires")
    func streamURLCarriesToken() throws {
        let part = try PlexTransport.decoder.decode(
            PlexPart.self,
            from: Data(#"{"id":"55","key":"/library/parts/55/1700000000/file.m4b","updatedAt":1700000000}"#.utf8)
        )
        let url = makeClient(StubHTTPClient()).streamURL(part: part).absoluteString
        #expect(url.contains("/library/parts/55/1700000000/file.m4b"))
        #expect(url.contains("X-Plex-Token=srv_token"))
    }
}
