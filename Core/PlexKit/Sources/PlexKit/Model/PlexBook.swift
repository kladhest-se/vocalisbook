import Foundation

/// A Plex album (`type=9`) presented as a book.
///
/// Plex has no concept of a narrator, a series, or a book-level duration, so
/// several fields here are best-effort. `duration` in particular is often absent
/// on the album and must be summed from the tracks — never trust it for the
/// playback timeline. Use it only to render an approximate length in a list.
public struct PlexBook: Decodable, Sendable, Hashable, Identifiable {
    public let ratingKey: String
    public let key: String
    public let title: String
    public let titleSort: String?
    /// Album artist, i.e. the author.
    public let author: String?
    public let authorRatingKey: String?
    public let summary: String?
    public let year: Int?
    public let thumb: String?
    public let art: String?
    /// Number of tracks, when the server reports it.
    public let leafCount: Int?
    public let viewedLeafCount: Int?
    /// Album-level duration in milliseconds. Frequently absent or wrong.
    public let approximateDurationMs: Int?
    public let addedAt: Date?
    public let updatedAt: Date?
    public let lastViewedAt: Date?
    public let viewOffsetMs: Int?
    public let studio: String?

    /// Whatever agent matched this book says it is.
    ///
    /// Kept raw. Turning it into a `BookIdentity` needs the server it came from,
    /// which this type has no business knowing — the caller has both.
    public let guid: String?

    /// Genres, as the server tags them.
    ///
    /// Empty on a book no agent has matched — `local://` albums carry no tags at
    /// all — so a library that has never been matched has no genres, and that is
    /// a metadata problem rather than something this app can fix.
    public let genres: [String]

    /// Narrators.
    ///
    /// Plex's music schema has no field for one, so VocalisMeta puts them in
    /// `Style` — which for music means a sub-genre and for an audiobook library
    /// means the person reading. Documented in that agent's "Metadata mapping
    /// for player apps": Style is narrators, and readers of a LibriVox project
    /// map the same way.
    public let narrators: [String]

    /// Every author, not only the one Plex made the album's artist.
    ///
    /// `Mood` carries them. The primary author is the album's parent artist and
    /// is already in `author`; this is the full credit, which matters for a book
    /// with two or three writers where Plex can only link to one.
    ///
    /// Series entries live in the same list and are filtered out here — the
    /// agent's rule is that a Mood beginning `Series: ` is a series and anything
    /// else is a person.
    public let authors: [String]

    /// Series this book belongs to, from the same `Mood` list.
    ///
    /// Without the prefix: `Series: Discworld` is stored as `Discworld`. A book
    /// can be in more than one, and the agent keeps each as its own exact value.
    public let series: [String]

    /// Where in each series, from `Sequence: Discworld #5`.
    ///
    /// Kept beside the series rather than folded into it, which is why the agent
    /// emits two Moods: `Series:` stays exactly matchable for grouping while the
    /// position varies per book.
    ///
    /// Split at the *final* ` #`, as the contract specifies, because a series
    /// name may contain both spaces and a hash.
    ///
    /// The position stays a string. It can be `3.5`, and the contract reserves
    /// the right to non-numeric positions later — a client that parsed it to an
    /// Int would silently drop half a book.
    public let sequences: [BookSequence]

    /// The recording language, from `Language: English`.
    ///
    /// Only present when the agent had evidence. Absence means unknown, not
    /// English.
    public let language: String?

    /// `Abridged` or `Unabridged`, from `Edition:`.
    ///
    /// Absence means unknown. The contract is explicit that an edition must not
    /// be inferred from a missing tag — plenty of unabridged recordings simply
    /// never say so.
    public let edition: String?

    public var id: String { ratingKey }

    /// The prefix that separates a series from a person in `Mood`.
    ///
    /// Matched exactly, as the agent specifies. Treating any Mood containing the
    /// word as a series would turn an author called "Series" — or a book whose
    /// co-author list happened to mention one — into a phantom series.
    private static let seriesPrefix = "Series: "
    private static let sequencePrefix = "Sequence: "
    private static let languagePrefix = "Language: "
    private static let editionPrefix = "Edition: "

    /// Every namespace the contract reserves.
    ///
    /// Checked as a set rather than one prefix, because the cost of missing one
    /// is that it appears as a person: a library would list "English" and
    /// "Unabridged" among its authors, which is the sort of thing that looks
    /// like a scanning fault rather than a parsing one.
    private static let reservedPrefixes = [
        seriesPrefix, sequencePrefix, languagePrefix, editionPrefix,
    ]

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, title, titleSort, summary, year, thumb, art
        case guid, Guid
        case parentTitle, parentRatingKey, studio
        case leafCount, viewedLeafCount, duration
        case addedAt, updatedAt, lastViewedAt, viewOffset
        case Genre, Mood, Style
    }

    /// One entry in one of Plex's tag lists.
    ///
    /// Plex sends `"Genre": [{"tag": "Fantasy"}]` — objects rather than strings,
    /// with an id and a filter alongside the name on some endpoints.
    private struct Tag: Decodable {
        let tag: String?

        /// A `Guid` child holds its value here rather than in `tag`.
        let id: String?
    }

    private static let spokenMetaScheme = "com.plexapp.agents.spokenmeta://"

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let ratingKey = c.plexString(.ratingKey) else {
            throw PlexError.decoding("PlexBook missing ratingKey")
        }
        self.ratingKey = ratingKey
        self.key = c.plexString(.key) ?? "/library/metadata/\(ratingKey)/children"
        self.title = c.plexString(.title).map(PlexProse.repairingMojibake) ?? "Untitled"
        self.titleSort = c.plexString(.titleSort).map(PlexProse.repairingMojibake)
        self.author = c.plexString(.parentTitle).map(PlexProse.repairingMojibake)
        self.authorRatingKey = c.plexString(.parentRatingKey)
        // Escaped on the wire; decoded once, here, rather than in each of the
        // three apps that display it and the store that caches it. The
        // encoding repair runs first — an ampersand is ASCII either way, so
        // order between the two never matters, but reading it as "fix what the
        // bytes say, then fix how they're escaped" is the honest one.
        self.summary = c.plexString(.summary)
            .map(PlexProse.repairingMojibake)
            .map(PlexProse.decodingEntities)
        self.year = c.plexInt(.year)
        self.thumb = c.plexString(.thumb)
        self.art = c.plexString(.art)
        self.leafCount = c.plexInt(.leafCount)
        self.viewedLeafCount = c.plexInt(.viewedLeafCount)
        self.approximateDurationMs = c.plexInt(.duration)
        self.addedAt = c.plexDate(.addedAt)
        self.updatedAt = c.plexDate(.updatedAt)
        self.lastViewedAt = c.plexDate(.lastViewedAt)
        self.viewOffsetMs = c.plexInt(.viewOffset)
        self.studio = c.plexString(.studio).map(PlexProse.repairingMojibake)
        // Attribute or child, because Plex builds differ.
        //
        // The contract says to support both and to prefer the VocalisMeta one:
        // an album can carry several — a legacy agent's, a Plex Music one — and
        // taking the first would be a coin toss on which server answered.
        let attribute = c.plexString(.guid)
        let children = ((try? c.decodeIfPresent([Tag].self, forKey: .Guid)) ?? [])
            .compactMap(\.id)

        let candidates = ([attribute] + children).compactMap { $0 }
        self.guid = candidates.first { $0.hasPrefix(Self.spokenMetaScheme) }
            ?? candidates.first

        // Missing entirely on most responses, which is not an error: the list
        // endpoint omits tags and the detail endpoint carries them.
        let tags = (try? c.decodeIfPresent([Tag].self, forKey: .Genre)) ?? []
        self.genres = tags.compactMap(\.tag).map(PlexProse.repairingMojibake).filter { !$0.isEmpty }

        let styles = (try? c.decodeIfPresent([Tag].self, forKey: .Style)) ?? []
        self.narrators = styles.compactMap(\.tag).map(PlexProse.repairingMojibake).filter { !$0.isEmpty }

        // One list, two meanings, split on the documented prefix. Repaired
        // before the split: the prefixes themselves — `Series:`, `Sequence:`
        // — are English and ASCII, so the repair leaves them exactly alone,
        // and everything after one is a name that can carry the same
        // corruption as any other field here.
        let moods = ((try? c.decodeIfPresent([Tag].self, forKey: .Mood)) ?? [])
            .compactMap(\.tag)
            .map(PlexProse.repairingMojibake)
            .filter { !$0.isEmpty }

        self.series = moods
            .filter { $0.hasPrefix(Self.seriesPrefix) }
            .map { String($0.dropFirst(Self.seriesPrefix.count)) }
            .filter { !$0.isEmpty }

        self.sequences = moods
            .filter { $0.hasPrefix(Self.sequencePrefix) }
            .compactMap { BookSequence(mood: String($0.dropFirst(Self.sequencePrefix.count))) }

        self.language = moods
            .first { $0.hasPrefix(Self.languagePrefix) }
            .map { String($0.dropFirst(Self.languagePrefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }

        self.edition = moods
            .first { $0.hasPrefix(Self.editionPrefix) }
            .map { String($0.dropFirst(Self.editionPrefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Anything left. A raw Mood is a person only after every reserved
        // namespace has been taken out of the list.
        self.authors = moods.filter { mood in
            !Self.reservedPrefixes.contains { mood.hasPrefix($0) }
        }
    }
}
