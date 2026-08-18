import Foundation

/// A book's identity, stable across servers where one exists.
///
/// Everything this app stores about listening — position, bookmarks, history —
/// has been keyed by Plex's `ratingKey`, which is per-server. The same audiobook
/// on two servers is two rating keys, so a device pointed at a different server
/// sees an unrelated book and iCloud sync treats them as unrelated too. That is
/// silent, and it is wrong.
///
/// VocalisMeta puts a provider identity in the Plex GUID, which is the same on
/// every server that matched the same edition. Where one exists, it is the
/// identity to use.
///
/// **Precedence, per the agent's client contract:**
///
/// 1. Audible — `spokenmeta:audible:us:B08G9PRS1K`
/// 2. LibriVox — `spokenmeta:librivox:52`
/// 3. An explicit ISBN or local identity, when the agent gains one
/// 4. Server plus rating key, which is per-server and the honest fallback
///
/// **A name-backed GUID is not a book identity.** The agent emits
/// `name:Kevin+J.+Anderson_us` as an *artist* identity, and two different books
/// by one author share it. Keying progress on that would merge them — one
/// position, one bookmark list, for every book that writer has published. It is
/// rejected here rather than ignored quietly, because the failure would look
/// like sync corruption rather than a parsing mistake.
public enum BookIdentity: Sendable, Hashable {

    /// An Audible edition: region and ASIN together.
    ///
    /// The contract keeps region in the key deliberately — the same ASIN in two
    /// stores is two catalogue editions. A client-level equivalence layer could
    /// relate them later without changing what is stored.
    case audible(region: String, asin: String)

    /// A LibriVox project.
    case librivox(id: String)

    /// A checksummed ISBN, canonicalised to ISBN-13 by the agent.
    case isbn(String)

    /// A deterministic fingerprint of local evidence: title, author, runtime to
    /// five minutes, language, abridgment.
    ///
    /// Weaker than the others by design. It lets an unmatched book survive a
    /// Plex rebuild or appear as the same book on another server, and it can
    /// legitimately change when somebody fixes their tags — so two differing
    /// `local:` identities are never merged automatically.
    case local(fingerprint: String)

    /// No identity the agent could emit. Per-server, and named as such so
    /// nothing mistakes it for something that travels.
    case server(serverIdentifier: String, ratingKey: String)

    /// The string this is stored and synced under.
    ///
    /// Prefixed by kind, so an ASIN can never collide with a LibriVox id or a
    /// rating key from a server that happens to use the same digits.
    public var key: String {
        switch self {
        case .audible(let region, let asin):
            return "spokenmeta:audible:\(region):\(asin)"
        case .librivox(let id):
            return "spokenmeta:librivox:\(id)"
        case .isbn(let isbn):
            return "spokenmeta:isbn:\(isbn)"
        case .local(let fingerprint):
            return "spokenmeta:local:\(fingerprint)"
        case .server(let serverIdentifier, let ratingKey):
            return "plex:\(serverIdentifier):\(ratingKey)"
        }
    }

    /// Whether this identity means the same book on another server.
    public var isPortable: Bool {
        switch self {
        case .audible, .librivox, .isbn, .local: return true
        case .server: return false
        }
    }

    /// How much the identity can be trusted to mean one edition.
    ///
    /// The contract separates these: Audible, LibriVox and ISBN identify an
    /// edition, while `local:` is evidence-based and may change when tags are
    /// fixed. Anything deciding whether to *merge* two rows needs to know which
    /// it has — merging on a strong identity is safe, merging two `local:`
    /// fingerprints on title alone is not.
    public var isStrong: Bool {
        switch self {
        case .audible, .librivox, .isbn: return true
        case .local, .server: return false
        }
    }

    /// Reads a Plex GUID, falling back to the server and rating key.
    ///
    /// The GUID is whatever the matching agent wrote, and most of them are not
    /// VocalisMeta: a `local://`, a legacy `com.plexapp.agents.*`, or nothing at
    /// all on an unmatched album. Anything unrecognised falls through to the
    /// per-server identity rather than being guessed at.
    public static func from(
        guid: String?,
        serverIdentifier: String,
        ratingKey: String
    ) -> BookIdentity {
        guard let provider = provider(from: guid) else {
            return .server(serverIdentifier: serverIdentifier, ratingKey: ratingKey)
        }
        return provider
    }

    /// The provider identity in a GUID, if it holds one this app can use.
    ///
    /// Each form is matched in full rather than split on a separator. The
    /// difference matters: splitting `name:Kevin+J.+Anderson_us` on its last
    /// underscore yields a perfectly well-formed identity that every book by
    /// that author shares. Requiring ten uppercase alphanumerics and a known
    /// marketplace makes that impossible rather than merely unlikely.
    static func provider(from guid: String?) -> BookIdentity? {
        guard let guid, let id = spokenMetaBody(of: guid) else { return nil }

        if let audible = audibleIdentity(id) { return audible }

        if let value = value(of: "librivox:", in: id),
           value.first != "0",
           value.allSatisfy(\.isNumber) {
            return .librivox(id: value)
        }

        if let value = value(of: "isbn:", in: id), isValidISBN13(value) {
            return .isbn(value)
        }

        if let value = value(of: "local:", in: id),
           value.count == 16,
           value.allSatisfy({ $0.isHexDigit }) {
            return .local(fingerprint: value.lowercased())
        }

        // Everything else, including `name:`, which is an artist.
        return nil
    }

    /// Thirteen digits *and* a correct check digit.
    ///
    /// The contract says an ISBN identity is emitted only for a valid checksum,
    /// so a client that accepts any thirteen digits is accepting identities the
    /// agent would never write. That is not a cosmetic difference: a corrupt or
    /// mistyped ISBN in one file would key progress under something no other
    /// device agrees with, and the book would quietly stop syncing.
    ///
    /// Alternating weights of one and three across the first twelve digits; the
    /// check digit is what takes the total to a multiple of ten.
    private static func isValidISBN13(_ value: String) -> Bool {
        guard value.count == 13 else { return false }

        let digits = value.compactMap(\.wholeNumberValue)
        guard digits.count == 13 else { return false }

        let total = digits.prefix(12).enumerated()
            .reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 1 : 3) }

        return (10 - total % 10) % 10 == digits[12]
    }

    /// `ASIN_region`: ten uppercase alphanumerics, then a marketplace.
    private static func audibleIdentity(_ id: String) -> BookIdentity? {
        guard let separator = id.lastIndex(of: "_") else { return nil }

        let asin = String(id[id.startIndex..<separator])
        let region = String(id[id.index(after: separator)...]).lowercased()

        guard asin.count == 10,
              asin.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter) }),
              marketplaces.contains(region)
        else { return nil }

        // Upper-cased in the canonical key, as the contract specifies, so one
        // edition cannot arrive under two spellings from two servers.
        return .audible(region: region, asin: asin.uppercased())
    }

    /// The marketplaces the agent supports. A fixed list rather than "two
    /// letters": `name:Someone_ab` would otherwise be an Audible identity.
    private static let marketplaces: Set<String> = [
        "au", "ca", "de", "es", "fr", "in", "it", "jp", "uk", "us",
    ]

    /// The part after a prefix, case-insensitively, or nil.
    private static func value(of prefix: String, in id: String) -> String? {
        guard id.lowercased().hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    /// The part of a VocalisMeta GUID that identifies the item.
    ///
    /// Three things have to be tolerated, all of them Plex's doing rather than
    /// the agent's: a `?lang=en` query, percent encoding, and a trailing model
    /// suffix — `/-1` in the builds seen so far, but the contract says `/number`,
    /// so any final path component that is a number goes.
    private static func spokenMetaBody(of guid: String) -> String? {
        let scheme = "com.plexapp.agents.spokenmeta://"
        guard guid.hasPrefix(scheme) else { return nil }

        var body = String(guid.dropFirst(scheme.count))

        if let query = body.firstIndex(of: "?") {
            body = String(body[body.startIndex..<query])
        }

        if let slash = body.lastIndex(of: "/") {
            let suffix = body[body.index(after: slash)...]
            let digits = suffix.hasPrefix("-") ? suffix.dropFirst() : suffix
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                body = String(body[body.startIndex..<slash])
            }
        }

        // Decoded after the structural characters are removed, so an encoded
        // `%3F` inside a value cannot be mistaken for the start of the query.
        let decoded = body.removingPercentEncoding ?? body
        return decoded.isEmpty ? nil : decoded
    }
}
