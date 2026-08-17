import Foundation

/// The connection this client is currently using to reach a server.
public struct ResolvedConnection: Sendable, Hashable {
    public let serverIdentifier: String
    public let baseURL: URL
    public let accessToken: String
    public let isLocal: Bool
    public let isRelay: Bool
    public let resolvedAt: Date
    /// Round-trip time of the probe, useful for showing why a connection was
    /// chosen and for deciding whether a re-race is worthwhile.
    public let probeLatency: Duration

    /// A memberwise initialiser, written out because Swift's synthesised one is
    /// `internal` however public the type is.
    ///
    /// That is not only a test inconvenience: reconnecting to a server already
    /// in the local store, without re-racing, means building one of these from
    /// outside PlexKit. A public struct nobody can construct is half a type.
    public init(
        serverIdentifier: String,
        baseURL: URL,
        accessToken: String,
        isLocal: Bool,
        isRelay: Bool,
        resolvedAt: Date,
        probeLatency: Duration
    ) {
        self.serverIdentifier = serverIdentifier
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.isLocal = isLocal
        self.isRelay = isRelay
        self.resolvedAt = resolvedAt
        self.probeLatency = probeLatency
    }
}

/// Picks the best reachable connection for a server.
///
/// Connections are probed in priority *tiers* rather than all at once: LAN
/// candidates race each other first, and remote candidates are only tried if
/// the whole local tier fails. Racing every candidate simultaneously would
/// often hand the win to a relay simply because it answered a few milliseconds
/// sooner than the LAN address, which is the wrong outcome every time.
public struct ConnectionRacer: Sendable {
    private let client: HTTPClient
    private let identity: PlexClientIdentity
    private let probeTimeout: Duration

    public init(
        client: HTTPClient,
        identity: PlexClientIdentity,
        probeTimeout: Duration = .seconds(3)
    ) {
        self.client = client
        self.identity = identity
        self.probeTimeout = probeTimeout
    }

    public func resolve(_ resource: PlexResource, fallbackToken: String) async throws -> ResolvedConnection {
        let token = resource.accessToken ?? fallbackToken
        let tiers = Dictionary(grouping: resource.connections, by: \.priority)
            .sorted { $0.key < $1.key }

        for (_, candidates) in tiers {
            if let winner = await race(candidates, token: token, resource: resource) {
                return winner
            }
        }
        throw PlexError.noReachableConnection
    }

    private func race(
        _ candidates: [PlexConnection],
        token: String,
        resource: PlexResource
    ) async -> ResolvedConnection? {
        await withTaskGroup(of: ResolvedConnection?.self) { group in
            for candidate in candidates {
                guard let url = candidate.url else { continue }
                group.addTask {
                    await probe(url: url, candidate: candidate, token: token, resource: resource)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private func probe(
        url: URL,
        candidate: PlexConnection,
        token: String,
        resource: PlexResource
    ) async -> ResolvedConnection? {
        let started = ContinuousClock.now
        var headers = identity.headers
        headers["X-Plex-Token"] = token

        let request = HTTPRequest(
            url: url.appendingPathComponent("identity"),
            headers: headers,
            timeout: probeTimeout
        )

        guard let response = try? await client.send(request), response.isSuccess else {
            return nil
        }
        // A reachable *something* is not necessarily the right something —
        // captive portals and reverse proxies answer 200 for anything.
        guard let identityBody = try? PlexTransport.decoder.decode(
            PlexServerIdentity.self,
            from: response.body
        ) else { return nil }

        if let machine = identityBody.machineIdentifier,
           machine != resource.clientIdentifier {
            return nil
        }

        return ResolvedConnection(
            serverIdentifier: resource.clientIdentifier,
            baseURL: url,
            accessToken: token,
            isLocal: candidate.local,
            isRelay: candidate.relay,
            resolvedAt: Date(),
            probeLatency: started.duration(to: .now)
        )
    }
}
