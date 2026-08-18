import Foundation

/// A collection as Plex reports it.
///
/// Server-side, and the natural home for a series: an audiobook library with the
/// Audnexus agent usually has one collection per series. Distinct from the
/// `collection` table in the local store, which is for collections a listener
/// makes themselves and which sync via CloudKit — Plex has no API for those.
public struct PlexCollection: Decodable, Sendable, Hashable, Identifiable {
    public let ratingKey: String
    public let key: String
    public let title: String
    public let titleSort: String?
    public let childCount: Int?
    public let thumb: String?
    public let summary: String?

    public var id: String { ratingKey }

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, title, titleSort, childCount, thumb, summary
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let ratingKey = c.plexString(.ratingKey) else {
            throw PlexError.decoding("PlexCollection missing ratingKey")
        }
        self.ratingKey = ratingKey
        self.key = c.plexString(.key) ?? "/library/collections/\(ratingKey)/children"
        self.title = c.plexString(.title).map(PlexProse.repairingMojibake) ?? "Untitled"
        self.titleSort = c.plexString(.titleSort).map(PlexProse.repairingMojibake)
        self.childCount = c.plexInt(.childCount)
        self.thumb = c.plexString(.thumb)
        self.summary = c.plexString(.summary)
            .map(PlexProse.repairingMojibake)
            .map(PlexProse.decodingEntities)
    }
}
