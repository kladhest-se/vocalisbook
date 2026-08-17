import Foundation

/// Response from `/identity` — the cheapest authenticated-free endpoint on a
/// server, which makes it the right probe for connection racing.
public struct PlexServerIdentity: Decodable, Sendable, Hashable {
    public let machineIdentifier: String?
    public let version: String?

    enum CodingKeys: String, CodingKey {
        case machineIdentifier, version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineIdentifier = c.plexString(.machineIdentifier)
        version = c.plexString(.version)
    }
}
