import Foundation

/// A plex.tv PIN awaiting authorisation.
public struct PlexPin: Decodable, Sendable, Hashable {
    public let id: Int
    public let code: String
    public let authToken: String?
    public let expiresAt: Date?
    public let clientIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case id, code, authToken, expiresAt, clientIdentifier
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.plexInt(.id), let code = c.plexString(.code) else {
            throw PlexError.decoding("PlexPin missing id or code")
        }
        self.id = id
        self.code = code
        self.authToken = c.plexString(.authToken)
        self.clientIdentifier = c.plexString(.clientIdentifier)

        // plex.tv returns ISO8601 here, unlike the epoch seconds used on the
        // media server endpoints.
        if let raw = c.plexString(.expiresAt) {
            self.expiresAt = ISO8601DateFormatter().date(from: raw)
        } else {
            self.expiresAt = nil
        }
    }

    public var isClaimed: Bool { authToken?.isEmpty == false }
}
