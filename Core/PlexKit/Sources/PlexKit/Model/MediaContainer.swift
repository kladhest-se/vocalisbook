import Foundation

/// Every `/library/...` response is wrapped in this envelope.
public struct MediaContainerResponse<Body: Decodable & Sendable>: Decodable, Sendable {
    public let mediaContainer: Body

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

public struct DirectoryContainer<Item: Decodable & Sendable>: Decodable, Sendable {
    public let size: Int
    public let directory: [Item]

    enum CodingKeys: String, CodingKey {
        case size
        case directory = "Directory"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.plexInt(.size) ?? 0
        directory = c.plexArray([Item].self, .directory)
    }
}

public struct MetadataContainer<Item: Decodable & Sendable>: Decodable, Sendable {
    public let size: Int
    public let totalSize: Int?
    public let offset: Int?
    public let metadata: [Item]

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset
        case metadata = "Metadata"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.plexInt(.size) ?? 0
        totalSize = c.plexInt(.totalSize)
        offset = c.plexInt(.offset)
        metadata = c.plexArray([Item].self, .metadata)
    }
}

/// A container that takes its items from either key.
///
/// Plex is not consistent about which one a list arrives under.
/// `/library/sections` returns `Directory`; `/library/sections/{key}/collections`
/// returns `Metadata` — and decoding that one as a `DirectoryContainer` produced
/// an empty array rather than an error, because a missing array is the ordinary
/// case in these responses and is treated as empty by design.
///
/// So Collections was empty on all three clients, with no failure anywhere: the
/// request succeeded, the decode succeeded, and the answer was nothing. Worse
/// than a crash, and it survived because every test in the repository speaks to
/// a stubbed `HTTPClient` that was written against the same wrong assumption.
///
/// Accepting both is not a workaround. These endpoints are undocumented and
/// differ between server versions, and a client that insists on one spelling is
/// making a bet it cannot check.
public struct ItemContainer<Item: Decodable & Sendable>: Decodable, Sendable {
    public let size: Int
    public let totalSize: Int?
    public let items: [Item]

    enum CodingKeys: String, CodingKey {
        case size, totalSize
        case metadata = "Metadata"
        case directory = "Directory"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.plexInt(.size) ?? 0
        totalSize = c.plexInt(.totalSize)

        let metadata = c.plexArray([Item].self, .metadata)
        items = metadata.isEmpty ? c.plexArray([Item].self, .directory) : metadata
    }
}

