import Foundation

public struct PlexResourceDirectory: Sendable {
    private let transport: PlexTransport
    private let baseURL: URL

    public init(transport: PlexTransport, baseURL: URL = URL(string: "https://plex.tv")!) {
        self.transport = transport
        self.baseURL = baseURL
    }

    /// Who the token belongs to.
    ///
    /// Only plex.tv can answer this: a server knows a token is authorised, not
    /// whose it is. Returns JSON rather than the XML most of plex.tv still
    /// speaks, so the Accept header matters.
    public func account(token: String) async throws -> PlexAccount {
        let request = HTTPRequest(url: baseURL.appendingPathComponent("api/v2/user"))
            .adding(headers: ["Accept": "application/json"])
        return try await transport.decode(PlexAccount.self, from: request, token: token)
    }

    /// Servers visible to this account, owned ones first and then by name.
    ///
    /// Anything that does not `provide` "server" is dropped: the same endpoint
    /// lists every device on the account, and a phone with Plex installed is a
    /// resource too.
    public func servers(token: String) async throws -> [PlexResource] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v2/resources"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1"),
            URLQueryItem(name: "includeIPv6", value: "1"),
        ]

        let all = try await transport.decode(
            [PlexResource].self,
            from: HTTPRequest(url: components.url!),
            token: token
        )
        return all
            .filter(\.isServer)
            .sorted { lhs, rhs in
                if lhs.owned != rhs.owned { return lhs.owned }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
