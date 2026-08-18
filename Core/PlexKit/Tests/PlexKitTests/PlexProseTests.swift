import Foundation
import Testing
import PlexKit

/// Plex hands back HTML-escaped prose and offers no way to ask it not to.
///
/// The visible symptom was a book synopsis reading `...NOW ON HBO.&nbsp;Here is
/// the fourth book` on all three clients at once, which is what a fault at the
/// model boundary looks like.
///
/// Imported without `@testable` on purpose: `PlexProse` is part of the surface
/// the apps use, and a test that reaches inside the module proves nothing about
/// whether it can be reached from outside it.
@Suite("Plex prose")
struct PlexProseTests {

    @Test("Named entities are decoded")
    func namedEntities() {
        #expect(PlexProse.decodingEntities("Tom &amp; Jerry") == "Tom & Jerry")
        #expect(PlexProse.decodingEntities("&lt;p&gt;") == "<p>")
        #expect(
            PlexProse.decodingEntities("ON HBO.&nbsp;Here is")
                == "ON HBO.\u{00A0}Here is"
        )
    }

    @Test("Numeric entities are decoded in both bases")
    func numericEntities() {
        #expect(PlexProse.decodingEntities("don&#8217;t") == "don\u{2019}t")
        #expect(PlexProse.decodingEntities("don&#x2019;t") == "don\u{2019}t")
    }

    /// The case that makes a naive implementation worse than no implementation.
    @Test("A bare ampersand in prose survives")
    func bareAmpersand() {
        #expect(PlexProse.decodingEntities("a & b") == "a & b")
        #expect(PlexProse.decodingEntities("trailing &") == "trailing &")
        // An ampersand, then a clause, then a semicolon. Anything scanning for
        // the next semicolon rather than a short run swallows "Spencer".
        #expect(
            PlexProse.decodingEntities("Marks & Spencer; a shop")
                == "Marks & Spencer; a shop"
        )
    }

    /// Unknown and malformed entities are left as themselves rather than
    /// guessed at or dropped. Text that looks wrong is recoverable; text that
    /// has been silently deleted is not.
    @Test("Unrecognised entities pass through untouched")
    func unrecognised() {
        #expect(PlexProse.decodingEntities("&unknownentity;") == "&unknownentity;")
        #expect(PlexProse.decodingEntities("&;") == "&;")
        // Beyond the range of a Unicode scalar.
        #expect(PlexProse.decodingEntities("&#999999999999;") == "&#999999999999;")
    }

    /// Exactly one level. Double-escaped input decodes to the escaped form,
    /// which is what it actually says — decoding until nothing changes would
    /// turn a summary quoting an entity into whatever it names.
    @Test("Decoding is not applied repeatedly")
    func singlePass() {
        #expect(PlexProse.decodingEntities("&amp;amp;") == "&amp;")
        #expect(PlexProse.decodingEntities("&&amp;") == "&&")
    }

    @Test("Text with no entities is returned unchanged")
    func passthrough() {
        let plain = "A perfectly ordinary sentence."
        #expect(PlexProse.decodingEntities(plain) == plain)
        #expect(PlexProse.decodingEntities("") == "")
    }

    /// The decode has to happen where the model is built, not where it is
    /// displayed — the store caches summaries, so escaped text would be written
    /// to disk and only look right after a view had touched it.
    @Test("A decoded book summary comes out of decoding")
    func bookSummaryIsDecoded() throws {
        let json = """
        {"ratingKey":"900","title":"A Book","parentTitle":"An Author",
         "summary":"Bought at Marks &amp; Spencer.&nbsp;Then read."}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        #expect(book.summary == "Bought at Marks & Spencer.\u{00A0}Then read.")
    }

    /// The visible symptom: a title arriving from Plex as `HjÃ¤ltar och
    /// monster pÃ¥ himlavalvet` — correct Swedish, UTF-8 encoded, then misread
    /// as Latin-1 and saved as if that misreading were the real text. Nothing
    /// in this app's own transport does this; it arrives already broken.
    @Test("UTF-8 bytes misread as Latin-1 are repaired")
    func mojibakeIsRepaired() {
        #expect(
            PlexProse.repairingMojibake("HjÃ¤ltar och monster pÃ¥ himlavalvet")
                == "Hjältar och monster på himlavalvet"
        )
    }

    /// The property that makes this safe to run unconditionally rather than
    /// needing to first detect which text is broken: a genuine accented
    /// character has no valid two-step misreading as anything else, so the
    /// repair's own round trip fails and the original is returned untouched.
    @Test("Text that was never corrupted is returned unchanged")
    func alreadyCorrectTextIsUntouched() {
        let correct = "Café Society"
        #expect(PlexProse.repairingMojibake(correct) == correct)

        let ascii = "The Hobbit"
        #expect(PlexProse.repairingMojibake(ascii) == ascii)

        let empty = ""
        #expect(PlexProse.repairingMojibake(empty) == empty)
    }

    /// Text outside Latin-1 entirely — Cyrillic, CJK, emoji — cannot be
    /// misread as Latin-1 bytes in the first place, so the first guard fails
    /// and nothing is attempted.
    @Test("Text with no Latin-1 reading at all is returned unchanged")
    func nonLatin1TextIsUntouched() {
        let cyrillic = "Дюна"
        #expect(PlexProse.repairingMojibake(cyrillic) == cyrillic)
    }

    /// Same boundary as the summary test above, for the field the bug was
    /// actually reported against: an author name, not a synopsis.
    @Test("A corrupted author name comes out repaired")
    func bookAuthorIsRepaired() throws {
        let json = """
        {"ratingKey":"900","title":"A Book",
         "parentTitle":"HjÃ¤ltar Publishing"}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        #expect(book.author == "Hjältar Publishing")
    }
}
