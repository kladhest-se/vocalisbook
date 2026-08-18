import Foundation

/// Plex prose arrives HTML-escaped.
///
/// Summaries are scraped from publisher metadata and come through the API with
/// their entities intact, so a book synopsis renders as
/// `THE BOOK BEHIND ... ON HBO.&nbsp;Here is the fourth book` on screen. There is
/// no flag to ask the server for decoded text; every client decodes it.
///
/// Done here, at the model boundary, rather than in the views. Three apps show
/// summaries and a fourth surface (the store) caches them — decoding in the
/// views would mean four copies, and a cache holding escaped text that only
/// looks right after a view has touched it.
///
/// Deliberately not `NSAttributedString(html:)`, which is the usual suggestion:
/// it pulls in WebKit, must run on the main thread, and is far too much
/// machinery for turning `&amp;` into an ampersand. It also strips tags, which
/// this does not — see below.
public enum PlexProse {

    /// Decodes HTML character entities, leaving everything else alone.
    ///
    /// Tags are *not* stripped. Plex summaries carry entities in practice and
    /// tags only rarely, and a naive tag stripper deletes any legitimate text
    /// between a `<` and a `>` — a summary discussing `a < b` loses the rest of
    /// its sentence. Removing markup correctly needs a parser; this needs a
    /// lookup table. If tags do turn up in the wild, they are a separate
    /// problem with a separate answer.
    public static func decodingEntities(_ text: String) -> String {
        // The overwhelmingly common case, and worth not allocating for.
        guard text.contains("&") else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        var rest = Substring(text)

        while let ampersand = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<ampersand]
            let body = rest.index(after: ampersand)

            // A bare ampersand in prose is ordinary and must survive. Only a
            // short run ending in a semicolon is a candidate, which is what
            // stops "Marks & Spencer; a shop" from swallowing the clause.
            guard let terminator = rest[body...]
                .prefix(maxEntityLength)
                .firstIndex(of: ";")
            else {
                out.append("&")
                rest = rest[body...]
                continue
            }

            if let replacement = replacement(for: rest[body..<terminator]) {
                out += replacement
                rest = rest[rest.index(after: terminator)...]
            } else {
                // Something shaped like an entity that is not one. Left exactly
                // as it was, rather than guessed at.
                out.append("&")
                rest = rest[body...]
            }
        }

        out += rest
        return out
    }

    /// Repairs text that is correct UTF-8, misread as Latin-1 somewhere
    /// upstream, and re-saved as if that misreading were the real text.
    ///
    /// The signature is specific: an accented character that should be one
    /// byte pair becomes two separate characters — `ä` arrives as `Ã¤`, `í`
    /// as `Ã` followed by a soft hyphen that most renderers draw as nothing,
    /// which is why the damage often reads as a single stray `Ã` rather than
    /// two visible characters. SpokenMeta and Plex's own agents are not
    /// consistent about the encoding they write metadata in, and this arrives
    /// already broken in the API response — nothing this app's own transport
    /// does causes it, and nothing here can ask Plex to store it correctly.
    ///
    /// The repair is the two steps in reverse: read the characters as if they
    /// were Latin-1 bytes, then decode those bytes as UTF-8. Applied to text
    /// that was never corrupted this way, both steps typically fail outright
    /// rather than producing new garbage — a genuine accented character has
    /// no valid two-step reading as anything else, and `String(data:encoding:)`
    /// returns `nil` rather than guessing. That is what makes this safe to run
    /// unconditionally rather than needing to first detect which text is
    /// broken.
    public static func repairingMojibake(_ text: String) -> String {
        // The overwhelmingly common case, and worth not allocating for: pure
        // ASCII cannot be mojibake by this mechanism, since every byte
        // involved is already identical under both encodings.
        guard text.utf8.contains(where: { $0 > 0x7F }) else { return text }

        guard let misreadAsLatin1 = text.data(using: .isoLatin1),
              let repaired = String(data: misreadAsLatin1, encoding: .utf8)
        else { return text }

        return repaired
    }

    /// Long enough for `#x1F600`, short enough that an ampersand followed by a
    /// clause and a semicolon is not mistaken for an entity.
    private static let maxEntityLength = 10

    private static func replacement(for body: Substring) -> String? {
        guard !body.isEmpty else { return nil }

        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }

        return named[String(body)]
    }

    /// The ones that actually appear in publisher metadata.
    ///
    /// Not the full HTML5 set — that is two thousand entries to catch `&zwnj;`
    /// in an audiobook synopsis. Anything missing falls through unchanged and
    /// is visible as itself, which is the same failure as today rather than a
    /// worse one.
    ///
    /// `&nbsp;` becomes a real non-breaking space rather than a plain one: it is
    /// what the source says, and the alternative is quietly rewriting the
    /// publisher's text.
    private static let named: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": "\u{00A0}",
        "hellip": "…",
        "mdash": "—",
        "ndash": "–",
        "lsquo": "\u{2018}",
        "rsquo": "\u{2019}",
        "ldquo": "\u{201C}",
        "rdquo": "\u{201D}",
        "bull": "•",
        "middot": "·",
        "deg": "°",
        "eacute": "é",
        "egrave": "è",
        "uuml": "ü",
        "ouml": "ö",
        "auml": "ä",
        "aring": "å",
        "oslash": "ø",
        "ccedil": "ç",
        "ntilde": "ñ",
        "trade": "™",
        "copy": "©",
        "reg": "®",
    ]
}
