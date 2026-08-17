import Foundation
import Testing
@testable import PlexKit

/// The client half of SpokenMeta's identity contract.
///
/// Worth testing thoroughly because it is pure, because getting it wrong is
/// silent, and because one of its rules exists to prevent data loss rather than
/// a wrong label.
@Suite("Book identity")
struct BookIdentityTests {

    // MARK: - Audible

    @Test("An Audible GUID gives region and ASIN")
    func audible() {
        let identity = BookIdentity.from(
            guid: "com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en",
            serverIdentifier: "srv",
            ratingKey: "900"
        )
        #expect(identity == .audible(region: "us", asin: "B08G9PRS1K"))
        #expect(identity.key == "spokenmeta:audible:us:B08G9PRS1K")
        #expect(identity.isPortable)
    }

    /// The same ASIN in two stores is two editions, with different narrators and
    /// runtimes, so the region is part of the identity rather than a detail.
    @Test("The same ASIN in two regions is two identities")
    func regionIsPartOfIdentity() {
        let us = BookIdentity.from(
            guid: "com.plexapp.agents.spokenmeta://B08G9PRS1K_us",
            serverIdentifier: "srv", ratingKey: "900"
        )
        let uk = BookIdentity.from(
            guid: "com.plexapp.agents.spokenmeta://B08G9PRS1K_uk",
            serverIdentifier: "srv", ratingKey: "900"
        )
        #expect(us != uk)
    }

    // MARK: - LibriVox

    @Test("A LibriVox GUID gives the project id")
    func librivox() {
        let identity = BookIdentity.from(
            guid: "com.plexapp.agents.spokenmeta://librivox:52?lang=en",
            serverIdentifier: "srv", ratingKey: "900"
        )
        #expect(identity == .librivox(id: "52"))
        #expect(identity.key == "spokenmeta:librivox:52")
    }

    /// A LibriVox id and an ASIN can never collide, whatever they contain.
    @Test("Keys are namespaced by kind")
    func keysAreNamespaced() {
        let librivox = BookIdentity.librivox(id: "52")
        let audible = BookIdentity.audible(region: "us", asin: "52")
        #expect(librivox.key != audible.key)
    }

    // MARK: - The rule that prevents data loss

    /// A name-backed GUID is an *artist* identity. Two books by one author share
    /// it, so keying progress on it would give every book Kevin J. Anderson has
    /// written a single shared position and one bookmark list.
    ///
    /// This is the test that matters: the failure it prevents looks like sync
    /// corruption rather than a parsing mistake.
    @Test("A name-backed GUID is not a book identity")
    func nameBackedIsRejected() {
        let identity = BookIdentity.from(
            guid: "com.plexapp.agents.spokenmeta://name:Kevin+J.+Anderson_us?lang=en",
            serverIdentifier: "srv", ratingKey: "900"
        )
        #expect(identity == .server(serverIdentifier: "srv", ratingKey: "900"))
        #expect(!identity.isPortable)
    }

    /// Two books by that author must stay apart.
    @Test("Two books with the same name-backed GUID keep separate identities")
    func nameBackedBooksStayApart() {
        let guid = "com.plexapp.agents.spokenmeta://name:Kevin+J.+Anderson_us"
        let first = BookIdentity.from(guid: guid, serverIdentifier: "srv", ratingKey: "900")
        let second = BookIdentity.from(guid: guid, serverIdentifier: "srv", ratingKey: "901")
        #expect(first != second)
    }

    // MARK: - What Plex does to a GUID on the way out

    @Test("A trailing /-1 is tolerated")
    func trailingSuffix() {
        let identity = BookIdentity.from(
            guid: "com.plexapp.agents.spokenmeta://B08G9PRS1K_us/-1",
            serverIdentifier: "srv", ratingKey: "900"
        )
        #expect(identity == .audible(region: "us", asin: "B08G9PRS1K"))
    }

    @Test("Percent encoding is tolerated")
    func percentEncoding() {
        let identity = BookIdentity.from(
            guid: "com.plexapp.agents.spokenmeta://librivox%3A52?lang=en",
            serverIdentifier: "srv", ratingKey: "900"
        )
        #expect(identity == .librivox(id: "52"))
    }

    /// The region is lower-cased and the ASIN upper-cased, so one edition
    /// cannot arrive under two spellings from two servers.
    @Test("Region and ASIN are canonicalised")
    func caseIsCanonicalised() {
        let identity = BookIdentity.from(
            guid: "com.plexapp.agents.spokenmeta://b08g9prs1k_US",
            serverIdentifier: "srv", ratingKey: "900"
        )
        #expect(identity.key == "spokenmeta:audible:us:B08G9PRS1K")
    }

    // MARK: - Everything else

    /// Most books in most libraries. An unmatched album, another agent, or no
    /// GUID at all: per-server, and honest about it.
    @Test("An unmatched book falls back to the server and rating key")
    func unmatchedFallsBack() {
        for guid in [nil, "local://900", "com.plexapp.agents.plexmusic://x", ""] {
            let identity = BookIdentity.from(
                guid: guid, serverIdentifier: "srv", ratingKey: "900"
            )
            #expect(identity == .server(serverIdentifier: "srv", ratingKey: "900"))
        }
    }

    /// The same book on two servers is two identities when nothing matched it,
    /// which is the limitation an ISBN or local identity would remove.
    @Test("Without a provider match, two servers mean two identities")
    func unmatchedDoesNotTravel() {
        let first = BookIdentity.from(guid: nil, serverIdentifier: "srv1", ratingKey: "900")
        let second = BookIdentity.from(guid: nil, serverIdentifier: "srv2", ratingKey: "742")
        #expect(first != second)
        #expect(!first.isPortable)
    }

    // MARK: - The contract's own vectors

    /// The six the contract lists, verbatim. If any of these change, the client
    /// is out of contract rather than merely buggy.
    @Test("The published contract vectors resolve as specified")
    func contractVectors() {
        let vectors: [(String, String)] = [
            ("com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en",
             "spokenmeta:audible:us:B08G9PRS1K"),
            ("com.plexapp.agents.spokenmeta://librivox%3A52?lang=en",
             "spokenmeta:librivox:52"),
            ("com.plexapp.agents.spokenmeta://isbn:9780593135204/-1?lang=en",
             "spokenmeta:isbn:9780593135204"),
            ("com.plexapp.agents.spokenmeta://local:0123456789ABCDEF?lang=en",
             "spokenmeta:local:0123456789abcdef"),
        ]

        for (guid, expected) in vectors {
            let identity = BookIdentity.from(
                guid: guid, serverIdentifier: "srv", ratingKey: "900"
            )
            #expect(identity.key == expected)
        }

        // The two that must *not* produce a book identity.
        for guid in [
            "com.plexapp.agents.spokenmeta://name:Kevin+J.+Anderson_us?lang=en",
            "local://122344",
        ] {
            let identity = BookIdentity.from(
                guid: guid, serverIdentifier: "srv", ratingKey: "900"
            )
            #expect(identity == .server(serverIdentifier: "srv", ratingKey: "900"))
        }
    }

    /// Each form is matched in full rather than split on a separator.
    ///
    /// The earlier version split on the last underscore and accepted whatever
    /// was either side, so `name:Someone_ab` was an Audible identity with a
    /// two-letter "region". Requiring ten alphanumerics and a real marketplace
    /// makes the collision impossible rather than unlikely.
    @Test("Malformed identifiers do not become identities")
    func malformedFormsAreRejected() {
        for guid in [
            "com.plexapp.agents.spokenmeta://noseparator_x",   // region unknown
            "com.plexapp.agents.spokenmeta://SHORT_us",        // ASIN too short
            "com.plexapp.agents.spokenmeta://B08G9PRS1K_zz",   // marketplace unknown
            "com.plexapp.agents.spokenmeta://librivox:052",    // leading zero
            "com.plexapp.agents.spokenmeta://librivox:abc",    // not a number
            "com.plexapp.agents.spokenmeta://isbn:123",        // not thirteen digits
            "com.plexapp.agents.spokenmeta://local:xyz",       // not sixteen hex
        ] {
            let identity = BookIdentity.from(
                guid: guid, serverIdentifier: "srv", ratingKey: "900"
            )
            #expect(identity == .server(serverIdentifier: "srv", ratingKey: "900"))
        }
    }

    /// The contract says `/-1` *or* `/number`.
    @Test("Any numeric model suffix is stripped")
    func numericModelSuffix() {
        for guid in [
            "com.plexapp.agents.spokenmeta://B08G9PRS1K_us/-1",
            "com.plexapp.agents.spokenmeta://B08G9PRS1K_us/7",
        ] {
            let identity = BookIdentity.from(
                guid: guid, serverIdentifier: "srv", ratingKey: "900"
            )
            #expect(identity == .audible(region: "us", asin: "B08G9PRS1K"))
        }
    }

    /// Strength is separate from portability: `local:` travels between servers
    /// but is evidence-based, and the contract forbids merging two of them on
    /// title alone.
    @Test("A local identity travels but is not strong")
    func localIsPortableButWeak() {
        let identity = BookIdentity.local(fingerprint: "0123456789abcdef")
        #expect(identity.isPortable)
        #expect(!identity.isStrong)
        #expect(BookIdentity.audible(region: "us", asin: "B08G9PRS1K").isStrong)
    }

    /// The contract emits an ISBN identity only for a valid checksum, so a
    /// client accepting any thirteen digits accepts identities the agent would
    /// never write — and a book keyed under one stops syncing without saying so.
    @Test("An ISBN with a bad check digit is not an identity")
    func isbnChecksum() {
        let good = BookIdentity.from(
            guid: "com.plexapp.agents.spokenmeta://isbn:9780593135204",
            serverIdentifier: "srv", ratingKey: "900"
        )
        #expect(good.key == "spokenmeta:isbn:9780593135204")

        for bad in [
            "9780593135205",   // one digit out
            "1234567890123",   // digits, not an ISBN
            "978059313520",    // twelve
        ] {
            let identity = BookIdentity.from(
                guid: "com.plexapp.agents.spokenmeta://isbn:\(bad)",
                serverIdentifier: "srv", ratingKey: "900"
            )
            #expect(identity == .server(serverIdentifier: "srv", ratingKey: "900"))
        }
    }

}
