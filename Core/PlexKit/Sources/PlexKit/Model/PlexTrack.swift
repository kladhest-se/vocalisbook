import Foundation

/// A Plex track (`type=10`) — one audio file inside a book.
///
/// `index` is the track number Plex assigns from tags. It is the ordering
/// authority for building a book timeline, but it is *not* guaranteed to be
/// dense or one-based on badly tagged libraries, so sort by it rather than
/// indexing into it.
public struct PlexTrack: Decodable, Sendable, Hashable, Identifiable {
    public let ratingKey: String
    public let key: String
    public let title: String
    public let index: Int?
    public let parentIndex: Int?
    public let durationMs: Int?
    public let viewOffsetMs: Int?
    public let viewCount: Int?
    public let lastViewedAt: Date?
    public let media: [PlexMedia]
    /// Present only when the request asked for `includeChapters=1`, and only
    /// when the server actually analysed the file. Absent is the common case.
    public let chapters: [PlexChapter]

    public var id: String { ratingKey }

    /// First playable part. Multi-part tracks exist in Plex but not in any
    /// sane audiobook library; if one appears we take the first and log it
    /// rather than inventing a merge strategy.
    public var primaryPart: PlexPart? { media.first?.parts.first }

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, title, index, parentIndex, duration
        case viewOffset, viewCount, lastViewedAt
        case media = "Media"
        case chapters = "Chapter"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let ratingKey = c.plexString(.ratingKey) else {
            throw PlexError.decoding("PlexTrack missing ratingKey")
        }
        self.ratingKey = ratingKey
        self.key = c.plexString(.key) ?? ""
        self.title = c.plexString(.title) ?? "Untitled"
        self.index = c.plexInt(.index)
        self.parentIndex = c.plexInt(.parentIndex)
        self.durationMs = c.plexInt(.duration)
        self.viewOffsetMs = c.plexInt(.viewOffset)
        self.viewCount = c.plexInt(.viewCount)
        self.lastViewedAt = c.plexDate(.lastViewedAt)
        self.media = c.plexArray([PlexMedia].self, .media)
        self.chapters = c.plexArray([PlexChapter].self, .chapters)
    }
}

public struct PlexMedia: Decodable, Sendable, Hashable {
    public let id: String?
    public let durationMs: Int?
    public let bitrate: Int?
    public let audioCodec: String?
    public let container: String?
    public let audioChannels: Int?
    public let parts: [PlexPart]

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, audioCodec, container, audioChannels
        case parts = "Part"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.plexString(.id)
        durationMs = c.plexInt(.duration)
        bitrate = c.plexInt(.bitrate)
        audioCodec = c.plexString(.audioCodec)
        container = c.plexString(.container)
        audioChannels = c.plexInt(.audioChannels)
        parts = c.plexArray([PlexPart].self, .parts)
    }
}

/// A file on disk on the server.
///
/// `updatedAt` is the cache key that matters: pairing it with `id` gives a
/// composite that changes whenever the file is retagged or replaced, which is
/// how downloaded copies and cached chapter lists detect staleness.
public struct PlexPart: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let key: String
    public let file: String?
    public let sizeBytes: Int?
    public let durationMs: Int?
    public let container: String?
    public let updatedAt: Date?
    public let hasThumbnail: Bool?

    enum CodingKeys: String, CodingKey {
        case id, key, file, size, duration, container, updatedAt, hasThumbnail
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.plexString(.id) else {
            throw PlexError.decoding("PlexPart missing id")
        }
        self.id = id
        self.key = c.plexString(.key) ?? ""
        self.file = c.plexString(.file)
        self.sizeBytes = c.plexInt(.size)
        self.durationMs = c.plexInt(.duration)
        self.container = c.plexString(.container)
        self.updatedAt = c.plexDate(.updatedAt)
        self.hasThumbnail = c.plexBool(.hasThumbnail)
    }

    /// Composite staleness key. Any cached artefact derived from this file —
    /// the downloaded copy, the parsed chapter list, the waveform — must be
    /// stored under this and invalidated when it changes.
    ///
    /// `updatedAt` is the right answer and not every server sends it.
    /// `plex-live.sh` found a real library whose parts carry none, and the old
    /// version fell back to the constant `0` — so every part's key was
    /// `<id>-0` for ever, and a file replaced or retagged on the server kept its
    /// key. The downloaded copy would then never be invalidated: you would go on
    /// playing the old audio, with nothing anywhere to suggest why.
    ///
    /// Size is the fallback, then duration. Neither is a timestamp, but both
    /// change when the bytes do, which is the only property this key needs.
    ///
    /// The prefix letter matters. Without it a part with `updatedAt` of 1700 and
    /// another with a size of 1700 bytes would collide — different files, one
    /// cache entry.
    public var cacheKey: String {
        if let updatedAt {
            return "\(id)-u\(Int(updatedAt.timeIntervalSince1970))"
        }
        if let sizeBytes {
            return "\(id)-s\(sizeBytes)"
        }
        if let durationMs {
            return "\(id)-d\(durationMs)"
        }
        // Nothing to go on. Stable, so the download still works; it simply
        // cannot notice the file changing underneath it. `plex-live.sh` reports
        // this against a real server, which is the only place it can be seen.
        return "\(id)-x"
    }
}

/// A chapter as Plex reports it. Offsets are relative to the *track*, not the
/// book — converting them to absolute positions is the timeline's job.
public struct PlexChapter: Decodable, Sendable, Hashable {
    public let id: String?
    public let index: Int?
    public let tag: String?
    public let startMs: Int
    public let endMs: Int

    enum CodingKeys: String, CodingKey {
        case id, index, tag
        case startTimeOffset, endTimeOffset
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let start = c.plexInt(.startTimeOffset), let end = c.plexInt(.endTimeOffset) else {
            throw PlexError.decoding("PlexChapter missing offsets")
        }
        self.id = c.plexString(.id)
        self.index = c.plexInt(.index)
        self.tag = c.plexString(.tag)
        self.startMs = start
        self.endMs = end
    }
}
