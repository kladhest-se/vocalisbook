import Foundation

/// A Plex library section. Audiobook libraries are almost always `type == .artist`
/// (a music library with the Audnexus agent), where artist = author,
/// album = book and track = file. A `.photo`/`.movie` section is never a
/// candidate and should be filtered out before the user ever sees the picker.
public struct PlexLibrarySection: Decodable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case movie, show, artist, photo
        case unknown
    }

    public let key: String
    public let title: String
    public let kind: Kind
    public let uuid: String?
    public let agent: String?
    public let scanner: String?

    public var id: String { key }

    /// Only music-shaped sections can hold audiobooks in the artist/album/track
    /// arrangement this client understands.
    public var canContainAudiobooks: Bool { kind == .artist }

    enum CodingKeys: String, CodingKey {
        case key, title, type, uuid, agent, scanner
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.plexString(.key) else {
            throw PlexError.decoding("PlexLibrarySection missing key")
        }
        self.key = key
        self.title = c.plexString(.title) ?? "Untitled"
        self.kind = Kind(rawValue: c.plexString(.type) ?? "") ?? .unknown
        self.uuid = c.plexString(.uuid)
        self.agent = c.plexString(.agent)
        self.scanner = c.plexString(.scanner)
    }
}
