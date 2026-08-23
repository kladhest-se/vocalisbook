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

    /// The literary work this recording is an edition of, from `Work-ID:`.
    ///
    /// Grouping only — see `WorkIdentity`'s own documentation for why this must
    /// never be used anywhere progress, bookmarks or completion are keyed.
    public let workIdentity: WorkIdentity?

    /// Every contributor the agent has matched to a stable source, from one
    /// `Contributor-ID:` Mood per person.
    ///
    /// Not every author or narrator will have one — the agent only emits this
    /// where it found a match — so this can be shorter than `authors` plus
    /// `narrators`, or empty, without that being a fault of either the agent or
    /// this parser.
    public let contributors: [ContributorIdentity]

    /// The work's first publication year, from `Work-Published:`.
    ///
    /// Distinct from `year`, which is this *recording's* release date as Plex's
    /// own `originallyAvailableAt` reports it — a 2019 audiobook of an 1899
    /// novel has both, and they mean different things on screen.
    public let workPublishedYear: Int?

    /// How the recording was produced, from `Production:` — "Full cast",
    /// "Dramatized", and so on, in whatever vocabulary the agent uses.
    ///
    /// Kept as whatever string arrives rather than matched against a fixed
    /// set, since the agent owns this vocabulary and a client that hardcoded
    /// it would need a release every time that vocabulary grew. Never inferred
    /// from narrator count — the contract is explicit that only an explicit
    /// value should ever be shown.
    public let productionType: String?

    /// Where a rating came from, from `Rating-Source:` — "Audible", for
    /// instance. `nil` alongside a `nil` `ratingCount` means no rating exists
    /// to attribute.
    public let ratingSource: String?

    /// How many ratings a book's rating is based on, from `Rating-Count:`.
    public let ratingCount: Int?

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
    private static let workIDPrefix = "Work-ID: "
    private static let contributorIDPrefix = "Contributor-ID: "
    private static let workPublishedPrefix = "Work-Published: "
    private static let productionPrefix = "Production: "
    private static let ratingSourcePrefix = "Rating-Source: "
    private static let ratingCountPrefix = "Rating-Count: "

    /// Every namespace the contract reserves.
    ///
    /// Checked as a set rather than one prefix, because the cost of missing one
    /// is that it appears as a person: a library would list "English" and
    /// "Unabridged" among its authors, which is the sort of thing that looks
    /// like a scanning fault rather than a parsing one. The v2/v3 namespaces
    /// belong here for the same reason a v1 one does — an unrecognised
    /// `Work-Published: 1950` would otherwise read as an author named exactly
    /// that.
    private static let reservedPrefixes = [
        seriesPrefix, sequencePrefix, languagePrefix, editionPrefix,
        workIDPrefix, contributorIDPrefix, workPublishedPrefix,
        productionPrefix, ratingSourcePrefix, ratingCountPrefix,
    ]

    /// From `metadata-contract-v3.json`'s own `value_regex` for
    /// `Work-Published:`: one to four digits, no leading zero.
    private static func isValidPublicationYear(_ value: String) -> Bool {
        guard let first = value.first, first != "0" else { return false }
        return (1...4).contains(value.count) && value.allSatisfy(\.isNumber)
    }

    /// The exact five values `metadata-contract-v3.json` allows for
    /// `Production:`. Anything else — including a value that merely looks
    /// plausible, like "Probably full cast" — is malformed per the
    /// contract's own test vectors.
    private static let allowedProductionTypes: Set<String> = [
        "Single narrator", "Multi-narrator", "Full cast",
        "Dramatized", "Community recording",
    ]

    /// The values `metadata-contract-v3.json` allows for `Rating-Source:`.
    /// `Ljudboksarkivet` added alongside `Audible` for Swedish-language
    /// libraries the same way `Language: Swedish` already works — this is
    /// exactly the "future contract adding a second provider" case the set
    /// (rather than a single string comparison) existed to make cheap.
    private static let allowedRatingSources: Set<String> = ["Audible", "Ljudboksarkivet"]

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
    /// Plex sends `"Genre": [{"id": 12345, "filter": "genre=12345", "tag":
    /// "Fantasy"}]` — objects rather than strings, and the real server always
    /// sends the id and the filter, not only the tag.
    ///
    /// Decoded field by field through the lenient helpers rather than by the
    /// synthesised conformance, and that is the whole point of this type
    /// existing rather than a plain struct: **`id` is a JSON number on a
    /// Genre, Mood or Style child and a string on a `Guid` child.** One type
    /// serves both, and the synthesised decoder asked `decodeIfPresent(String
    /// .self)` for it, which does not return nil on a number — it throws.
    ///
    /// The throw was invisible. `plexArray` decodes element by element and
    /// skips what it cannot read, which is exactly right for one malformed
    /// entry in a good list and exactly wrong here, where *every* entry has a
    /// numeric id and so *every* entry was skipped. A book came back with an
    /// empty `narrators`, an empty `genres` and an empty `moods` — no error,
    /// no warning, just a library where nobody had read anything and the
    /// agent appeared to have written no tags at all.
    ///
    /// Nothing in the test fixtures caught it because every one of them was
    /// written as `{"tag": "..."}` with no id, which is a shape Plex never
    /// actually sends. The tests agreed with each other rather than with the
    /// server.
    private struct Tag: Decodable {
        let tag: String?

        /// A `Guid` child holds its value here rather than in `tag`.
        let id: String?

        private enum CodingKeys: String, CodingKey {
            case tag, id
        }

        init(from decoder: any Decoder) throws {
            // Still throws for an element that is not an object at all — a
            // bare string in the middle of the list is genuinely malformed
            // and should still be skipped rather than read as an empty tag.
            let c = try decoder.container(keyedBy: CodingKeys.self)

            // Lenient on `id`, strict on `tag`, and the asymmetry is the
            // whole point rather than an oversight.
            //
            // `id` is the field Plex genuinely sends two ways: a number on a
            // Genre, Mood or Style child and a string on a `Guid` child. That
            // is a server telling the truth in two dialects, and reading both
            // is what this type is for.
            //
            // `tag` is always a string. A numeric one is not a dialect, it is
            // malformed — and reading it leniently turned `{"tag": 12345}`
            // into an author called "12345", which is worse than dropping it.
            // `plexString` on both fields is what did that: it was written to
            // rescue the id and quietly rescued a value nobody wanted rescued.
            // Caught by `oneMalformedMoodEntryDoesNotLoseTheRest`, which
            // existed for a different reason entirely and turned out to pin
            // this down exactly.
            //
            // A `nil` tag is not fatal to the element or the list: every
            // caller reads these through `compactMap(\.tag)`, so this drops
            // out on its own, which is the same thing the old strict decoder
            // achieved by throwing.
            tag = (try? c.decodeIfPresent(String.self, forKey: .tag)) ?? nil
            id = c.plexString(.id)
        }
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
        let children = c.plexArray([Tag].self, .Guid)
            .compactMap(\.id)

        let candidates = ([attribute] + children).compactMap { $0 }
        self.guid = candidates.first { $0.hasPrefix(Self.spokenMetaScheme) }
            ?? candidates.first

        // Missing entirely on most responses, which is not an error: the list
        // endpoint omits tags and the detail endpoint carries them.
        let tags = c.plexArray([Tag].self, .Genre)
        self.genres = tags.compactMap(\.tag).map(PlexProse.repairingMojibake).filter { !$0.isEmpty }

        let styles = c.plexArray([Tag].self, .Style)
        self.narrators = styles.compactMap(\.tag).map(PlexProse.repairingMojibake).filter { !$0.isEmpty }

        // One list, two meanings, split on the documented prefix. Repaired
        // before the split: the prefixes themselves — `Series:`, `Sequence:`
        // — are English and ASCII, so the repair leaves them exactly alone,
        // and everything after one is a name that can carry the same
        // corruption as any other field here.
        let moods = c.plexArray([Tag].self, .Mood)
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

        // A work identity, kept firmly apart from the recording's own
        // `BookIdentity` — see that type and `WorkIdentity`'s own
        // documentation for why. `.first`, matching `language` and `edition`:
        // a book is an edition of exactly one work.
        self.workIdentity = moods
            .first { $0.hasPrefix(Self.workIDPrefix) }
            .map { String($0.dropFirst(Self.workIDPrefix.count)) }
            .flatMap { WorkIdentity(mood: $0) }

        // Every contributor, not `.first` — a book can credit several authors
        // and narrators, each with their own `Contributor-ID:` Mood.
        // `compactMap` rather than treating a malformed one as fatal: one
        // contributor the agent could not fully match should not cost the
        // rest of the book its metadata.
        self.contributors = moods
            .filter { $0.hasPrefix(Self.contributorIDPrefix) }
            .map { String($0.dropFirst(Self.contributorIDPrefix.count)) }
            .compactMap { ContributorIdentity(mood: $0) }

        // Validated against the contract's own value_regex
        // (`^[1-9][0-9]{0,3}$`) rather than just parsed: a leading zero or a
        // fifth digit is not a year the agent's own contract considers
        // well-formed, even though `Int(...)` would happily parse either.
        self.workPublishedYear = moods
            .first { $0.hasPrefix(Self.workPublishedPrefix) }
            .map { String($0.dropFirst(Self.workPublishedPrefix.count)) }
            .flatMap { Self.isValidPublicationYear($0) ? Int($0) : nil }

        // Validated against the contract's exact five allowed values
        // (`metadata-contract-v3.json`) rather than accepted as free text.
        // An earlier version of this stored whatever string arrived on the
        // theory that the agent owns this vocabulary — reasonable in
        // isolation, but the contract's own test vectors reject a value
        // like "Probably full cast" outright, and a client that displayed
        // it anyway would be showing something the contract calls
        // malformed as though it were real data.
        self.productionType = moods
            .first { $0.hasPrefix(Self.productionPrefix) }
            .map { String($0.dropFirst(Self.productionPrefix.count)) }
            .flatMap { Self.allowedProductionTypes.contains($0) ? $0 : nil }

        // Validated against the contract's allowed values — v3 lists
        // "Audible" and "Ljudboksarkivet", and both are in the set. If
        // VocalisMeta ever adds a third rating provider, this set needs
        // updating alongside
        // it; this is not a general-purpose free-text field the way
        // `productionType`'s predecessor was mistakenly treated as one.
        self.ratingSource = moods
            .first { $0.hasPrefix(Self.ratingSourcePrefix) }
            .map { String($0.dropFirst(Self.ratingSourcePrefix.count)) }
            .flatMap { Self.allowedRatingSources.contains($0) ? $0 : nil }

        self.ratingCount = moods
            .first { $0.hasPrefix(Self.ratingCountPrefix) }
            .map { String($0.dropFirst(Self.ratingCountPrefix.count)) }
            .flatMap { Int($0) }

        // Anything left. A raw Mood is a person only after every reserved
        // namespace has been taken out of the list.
        self.authors = moods.filter { mood in
            !Self.reservedPrefixes.contains { mood.hasPrefix($0) }
        }
    }
}
