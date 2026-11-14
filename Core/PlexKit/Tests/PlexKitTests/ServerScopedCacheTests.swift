import Foundation
import Testing
@testable import PlexKit

@Suite("Server-scoped audio identities")
struct ServerScopedCacheTests {
    private func part(size: Int = 100) throws -> PlexPart {
        try JSONDecoder().decode(PlexPart.self, from: Data("{\"id\":\"55\",\"key\":\"/part.mp3\",\"size\":\(size)}".utf8))
    }
    @Test("Identical part numbers and sizes on two servers do not collide")
    func differentServers() throws {
        let part = try part()
        #expect(part.cacheKey(serverIdentifier: "server-A") != part.cacheKey(serverIdentifier: "server-B"))
        #expect(part.cacheKey(serverIdentifier: "server-A") == part.cacheKey(serverIdentifier: "server-A"))
    }
    @Test("File changes still invalidate the scoped key")
    func changedFile() throws {
        #expect(try part(size: 100).cacheKey(serverIdentifier: "A") != part(size: 200).cacheKey(serverIdentifier: "A"))
    }
    @Test("Server identities cannot create paths or oversized file names")
    func filenameSafety() throws {
        let key = try part().cacheKey(serverIdentifier: String(repeating: "../private/", count: 100))
        #expect(key.count == 66)
        #expect(!key.contains("/") && !key.contains(".."))
    }
}
