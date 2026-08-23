import Foundation

/// A contributor's stable identity, from a
/// `Contributor-ID: author:openlibrary:OL2162289A = Andy Weir` Mood.
///
/// A display name alone is not a safe key: two different people can share
/// one, and the same person's name can be transliterated, abbreviated or
/// corrected differently across editions and recordings. Where the agent has
/// matched a contributor to a source, that match is the identity; the display
/// name is only what gets shown, never what gets compared. Two contributors
/// are never merged just because their names read the same — that is exactly
/// the mistake having a stable key exists to avoid.
public struct ContributorIdentity: Sendable, Hashable {

    /// `author` or `narrator` — the only two roles VocalisMeta's own
    /// published contract (`metadata-contract-v3.json`) documents.
    ///
    /// Validated, not merely recorded: the contract's own test vectors
    /// reject a `translator:` entry outright rather than accepting it with
    /// an unfamiliar role, and this matches that. An earlier version of this
    /// type accepted any role string on the theory that a role this client
    /// has no page for yet should still parse — reasonable in isolation, but
    /// wrong against what the contract actually specifies, which is a fixed
    /// set of two.
    public let role: String

    /// The string this contributor is keyed under:
    /// `spokenmeta:contributor:<role>:<source>:<identifier>`.
    public let key: String

    /// The name to display.
    ///
    /// Deliberately not part of `key` — the entire point of having a stable
    /// key is that the display name can be corrected, retranslated or
    /// reformatted across editions without the identity moving underneath it.
    public let displayName: String

    /// Which source the identifier came from — `audible`, `librivox`,
    /// `openlibrary` or `name`.
    ///
    /// Kept as a field rather than re-parsed out of `key` at each use, because
    /// the difference between the first three and the last one is a difference
    /// the contract itself draws and callers have to act on. See
    /// `isProviderBacked`.
    public let source: String

    /// Whether an outside provider stands behind this identity.
    ///
    /// The contract states both halves of this in its own rules:
    /// `provider_contributor_identifier_is_authoritative_only_with_a_valid_source_id`,
    /// and separately that a `name:` identifier
    /// `is_a_deterministic_narrator_fallback_not_an_authoritative_person_id`.
    ///
    /// So a `name:` identity is a *grouping* key and nothing more: it is a
    /// hash of the name, which makes it stable across editions and servers —
    /// worth having, since two spellings of one recording's credits will at
    /// least agree with themselves — but it says nothing about who the person
    /// is. Two different people with the same name hash to the same value, and
    /// no amount of it being sixteen hex digits changes that it is still the
    /// name doing the work. Where both kinds exist for one person, the
    /// provider-backed one wins.
    public var isProviderBacked: Bool { source != "name" }

    /// Reads the part after `Contributor-ID: `.
    ///
    /// `<role>:<source>:<identifier> = <name>`, split on the first ` = `
    /// rather than the last. A display name is free text and could in
    /// principle contain almost anything; the left-hand side is exactly three
    /// colon-separated fields with no spaces of its own, which makes it the
    /// more reliable side to anchor the split on.
    ///
    /// The role and the source-specific identifier shape are both validated
    /// against the contract's own regexes rather than just checked for
    /// non-emptiness — `openlibrary:OL123W` (a work ID's own suffix, not a
    /// contributor's) is exactly the kind of value that looks well-formed to
    /// a loose check but is explicitly malformed per the contract's test
    /// vectors.
    public init?(mood: String) {
        guard let equals = mood.range(of: " = ") else { return nil }

        let identity = String(mood[mood.startIndex..<equals.lowerBound])
        let name = String(mood[equals.upperBound...])
        guard !name.isEmpty else { return nil }

        let parts = identity.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        let role = String(parts[0])
        let source = String(parts[1])
        let sourceID = String(parts[2])
        guard Self.roles.contains(role),
              Self.isSourceAllowed(source: source, for: role),
              Self.isValidSourceID(source: source, id: sourceID) else {
            return nil
        }

        self.role = role
        self.source = source
        self.key = "spokenmeta:contributor:\(identity)"
        self.displayName = name
    }

    /// Whether a stored canonical key came from a provider rather than a name.
    ///
    /// The store keeps the key string and not the parsed value, and the
    /// precedence between two identities for one person has to be decided
    /// there as much as here. Reads the source back out of
    /// `spokenmeta:contributor:<role>:<source>:<identifier>`; anything that is
    /// not that shape is not provider-backed, since an unparseable key is not
    /// evidence of a provider.
    public static func isProviderBacked(key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        // spokenmeta / contributor / role / source / identifier
        guard parts.count >= 5, parts[0] == "spokenmeta", parts[1] == "contributor" else {
            return false
        }
        return parts[3] != "name"
    }

    private static let roles: Set<String> = ["author", "narrator"]

    /// The four sources v3 documents, each with its own identifier shape.
    ///
    /// Four, not three. `name` was missing here and every `name:` identifier
    /// was therefore rejected as malformed — which on a real library is most
    /// of them, since a narrator rarely has an Audible or LibriVox page of
    /// their own. A twelve-narrator recording sent twelve `Contributor-ID:`
    /// Moods and the client kept none.
    ///
    /// Checked against `client-contract/metadata-contract-v3.json` directly
    /// rather than from memory of it. Its `source_identifier_regex` lists
    /// `audible`, `librivox`, `openlibrary` and `name`, and the regexes below
    /// are those four transcribed:
    ///
    /// - `audible`: `^[A-Z0-9]{10}$`
    /// - `librivox`: `^[1-9][0-9]{0,9}$`
    /// - `openlibrary`: `^OL[0-9]+A$`
    /// - `name`: `^[0-9a-f]{16}$`
    ///
    /// The `name` case is lowercase hex specifically, so it is spelled out as
    /// a set rather than leaning on `isHexDigit` — that property also accepts
    /// uppercase and the fullwidth forms, and an identifier the contract calls
    /// malformed should stay malformed here.
    private static func isValidSourceID(source: String, id: String) -> Bool {
        switch source {
        case "audible":
            return id.count == 10 && id.allSatisfy { $0.isASCII && ($0.isNumber || $0.isUppercase) }
        case "librivox":
            guard let first = id.first, first != "0" else { return false }
            return id.count <= 10 && id.allSatisfy(\.isNumber)
        case "openlibrary":
            guard id.hasPrefix("OL"), id.hasSuffix("A") else { return false }
            let digits = id.dropFirst(2).dropLast(1)
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        case "name":
            return id.count == 16 && id.allSatisfy { Self.lowercaseHex.contains($0) }
        default:
            return false
        }
    }

    private static let lowercaseHex: Set<Character> = Set("0123456789abcdef")

    /// Which sources a role may use.
    ///
    /// `name` is narrator-only, which the integration document states outright:
    /// it is a fingerprint of the narrator's normalized display name, emitted
    /// when a catalogue supplies a narrator name but no identifier for them.
    /// An author always has a provider behind them or has no contributor
    /// identity at all, so `author:name:...` is not a thing the agent emits and
    /// not a thing to accept.
    private static func isSourceAllowed(source: String, for role: String) -> Bool {
        source != "name" || role == "narrator"
    }

}
