import Foundation

/// One entry in a Plex tag directory: a Mood, Style or Genre the server indexes.
///
/// The `key` is what filters by it — an opaque identifier Plex assigns, not the
/// title. Filtering by title would break on any name containing a character the
/// query string treats specially, and Plex offers the key precisely so nobody
/// has to.
public struct PlexTag: Decodable, Sendable, Hashable, Identifiable {
    public let key: String
    public let title: String

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, title, fastKey
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Plex sends the identifier as `key` on some builds and a whole filter
        // path as `fastKey` on others. The identifier is the tail either way.
        let raw = c.plexString(.key) ?? c.plexString(.fastKey) ?? ""
        if let equals = raw.lastIndex(of: "=") {
            key = String(raw[raw.index(after: equals)...])
        } else {
            key = raw
        }

        title = c.plexString(.title) ?? ""
    }

    public init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}
