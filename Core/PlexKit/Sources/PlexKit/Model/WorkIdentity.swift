import Foundation

/// A literary work's identity, from a `Work-ID: openlibrary:OL12345W` Mood.
///
/// Grouping only. Two recordings sharing a work identity are editions of the
/// same book — an abridgment and its unabridged twin, a re-recording, a
/// different narrator's take — and belong together on an "other editions"
/// screen. They do not belong together anywhere progress, bookmarks,
/// completion or downloads are read from: those stay keyed by `BookIdentity`,
/// which names a *recording*, not a work. Conflating the two would mean
/// finishing one narrator's take marks a different narrator's recording
/// finished too — a correctness bug, not a display one, which is why this is
/// its own type rather than another case on `BookIdentity`.
public struct WorkIdentity: Sendable, Hashable {

    /// The string this work is grouped and displayed under.
    public let key: String

    /// Reads the part after `Work-ID: `.
    ///
    /// Validated against VocalisMeta's own published contract
    /// (`metadata-contract-v2.json`), not just parsed loosely: the source
    /// must be exactly `openlibrary`, and the identifier must match
    /// `^OL[0-9]+W$`. An `OL12345M` — a real value the contract's own test
    /// vectors use as the malformed case — looks well-formed to a casual
    /// "two non-empty colon-separated fields" check, but the contract is
    /// explicit that it must be ignored, not accepted as a work identity
    /// with an unusual suffix. `Work-ID:` stays reserved either way — see
    /// `PlexBook.reservedPrefixes` — this only decides whether the *value*
    /// is trusted as an identity.
    public init?(mood: String) {
        guard let separator = mood.firstIndex(of: ":") else { return nil }

        let source = String(mood[mood.startIndex..<separator])
        let identifier = String(mood[mood.index(after: separator)...])
        guard source == "openlibrary", Self.isValidOpenLibraryWorkID(identifier) else { return nil }

        self.key = "spokenmeta:work:\(source):\(identifier)"
    }

    private static func isValidOpenLibraryWorkID(_ identifier: String) -> Bool {
        guard identifier.hasPrefix("OL"), identifier.hasSuffix("W") else { return false }
        let digits = identifier.dropFirst(2).dropLast(1)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}
