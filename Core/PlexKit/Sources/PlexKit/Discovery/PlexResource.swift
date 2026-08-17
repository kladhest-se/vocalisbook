import Foundation

/// A device registered to the account. We only care about ones that
/// `provides` "server".
public struct PlexResource: Decodable, Sendable, Hashable, Identifiable {
    public let clientIdentifier: String
    public let name: String
    public let product: String?
    public let productVersion: String?
    public let platform: String?
    public let provides: String
    public let owned: Bool

    /// Who shares it, when it is not yours.
    ///
    /// Plex sends the owner's account name on shared servers and omits it on
    /// your own. Worth showing because "which of my friends is this" is the only
    /// question a server picker has to answer that the name alone cannot.
    public let sourceTitle: String?
    public let accessToken: String?
    public let connections: [PlexConnection]

    public var id: String { clientIdentifier }
    public var isServer: Bool { provides.split(separator: ",").contains("server") }

    /// Whose server this is, in one line.
    ///
    /// Here rather than in each app's picker, so the three do not drift into
    /// three different ways of saying the same thing — which is what happened to
    /// the line this replaced.
    ///
    /// Plex omits `sourceTitle` on your own servers and, occasionally, on shared
    /// ones too, so an unowned server with no name attached says only that it is
    /// shared. That is still true, and better than naming the wrong person.
    public var ownership: String {
        if owned { return "Yours" }
        if let sourceTitle, !sourceTitle.isEmpty { return "Shared by \(sourceTitle)" }
        return "Shared with you"
    }

    enum CodingKeys: String, CodingKey {
        case clientIdentifier, name, product, productVersion, platform
        case provides, owned, accessToken, sourceTitle
        case connections
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let clientIdentifier = c.plexString(.clientIdentifier) else {
            throw PlexError.decoding("PlexResource missing clientIdentifier")
        }
        self.clientIdentifier = clientIdentifier
        self.name = c.plexString(.name) ?? "Plex Server"
        self.product = c.plexString(.product)
        self.productVersion = c.plexString(.productVersion)
        self.platform = c.plexString(.platform)
        self.provides = c.plexString(.provides) ?? ""
        self.owned = c.plexBool(.owned) ?? false
        self.sourceTitle = c.plexString(.sourceTitle)
        self.accessToken = c.plexString(.accessToken)
        self.connections = c.plexArray([PlexConnection].self, .connections)
    }
}

public struct PlexConnection: Decodable, Sendable, Hashable {
    public let uri: String
    public let address: String?
    public let port: Int?
    public let networkProtocol: String?
    public let local: Bool
    public let relay: Bool
    public let ipv6: Bool

    public var url: URL? { URL(string: uri) }

    /// Lower sorts first. A LAN address beats a direct remote address, which
    /// beats a relay — relays are bandwidth-capped by Plex and will stutter on
    /// a high-bitrate file. IPv6 is deprioritised within each tier because
    /// homelab v6 paths are the ones most likely to black-hole.
    public var priority: Int {
        var score = relay ? 200 : (local ? 0 : 100)
        if ipv6 { score += 10 }
        return score
    }

    enum CodingKeys: String, CodingKey {
        case uri, address, port, local, relay, IPv6
        case networkProtocol = "protocol"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let uri = c.plexString(.uri) else {
            throw PlexError.decoding("PlexConnection missing uri")
        }
        self.uri = uri
        self.address = c.plexString(.address)
        self.port = c.plexInt(.port)
        self.networkProtocol = c.plexString(.networkProtocol)
        self.local = c.plexBool(.local) ?? false
        self.relay = c.plexBool(.relay) ?? false
        self.ipv6 = c.plexBool(.IPv6) ?? false
    }
}
