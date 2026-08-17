import Foundation

/// The signed-in Plex account.
///
/// Fetched from plex.tv rather than from the server: a server knows which token
/// is talking to it, not who owns it. This is the only place the app learns a
/// person's own name.
public struct PlexAccount: Decodable, Sendable, Hashable {
    public let id: Int?
    public let username: String
    public let title: String?
    public let email: String?
    public let thumb: String?

    /// What to show. `title` is the friendly name someone set; `username` is
    /// what they log in with, and is always there.
    public var displayName: String {
        title?.isEmpty == false ? title! : username
    }

    enum CodingKeys: String, CodingKey {
        case id, username, title, email, thumb
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.plexInt(.id)
        self.username = c.plexString(.username) ?? c.plexString(.title) ?? "Plex user"
        self.title = c.plexString(.title)
        self.email = c.plexString(.email)
        self.thumb = c.plexString(.thumb)
    }
}
