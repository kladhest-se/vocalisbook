import Foundation
import Testing
@testable import PlexKit

@Suite("Contributor identity")
struct ContributorIdentityTests {

    @Test("Role, source, identifier and display name all parse")
    func basicParse() {
        let contributor = ContributorIdentity(
            mood: "author:openlibrary:OL2162289A = Andy Weir"
        )
        #expect(contributor?.role == "author")
        #expect(contributor?.key == "spokenmeta:contributor:author:openlibrary:OL2162289A")
        #expect(contributor?.displayName == "Andy Weir")
    }

    @Test("A narrator role parses the same way as an author role")
    func narratorRole() {
        let contributor = ContributorIdentity(mood: "narrator:librivox:20 = Ray Example")
        #expect(contributor?.role == "narrator")
        #expect(contributor?.key == "spokenmeta:contributor:narrator:librivox:20")
    }

    @Test("A display name containing a colon still parses")
    func displayNameWithColon() {
        // The identity side is fixed-shape (three colon-separated fields, no
        // spaces); splitting on " = " rather than the last colon is what
        // makes a name like this safe.
        let contributor = ContributorIdentity(
            mood: "author:openlibrary:OL1A = Weir, Andy: A Retrospective"
        )
        #expect(contributor?.displayName == "Weir, Andy: A Retrospective")
    }

    @Test("A missing display name is not a contributor identity")
    func noEquals() {
        #expect(ContributorIdentity(mood: "author:openlibrary:OL2162289A") == nil)
    }

    @Test("An empty display name is rejected")
    func emptyName() {
        #expect(ContributorIdentity(mood: "author:openlibrary:OL2162289A = ") == nil)
    }

    @Test("Fewer than three identity fields is rejected")
    func tooFewFields() {
        #expect(ContributorIdentity(mood: "author:openlibrary = Andy Weir") == nil)
    }

    @Test("An empty field among the three is rejected")
    func emptyMiddleField() {
        #expect(ContributorIdentity(mood: "author::OL2162289A = Andy Weir") == nil)
    }

    @Test("Two people with the same display name keep different keys")
    func sameNameDifferentSource() {
        let a = ContributorIdentity(mood: "author:openlibrary:OL1A = J. Smith")
        let b = ContributorIdentity(mood: "author:openlibrary:OL2A = J. Smith")
        #expect(a?.key != b?.key)
        #expect(a?.displayName == b?.displayName)
    }

    // The following match VocalisMeta's own published contract
    // (metadata-contract-v3.json) and its test vectors directly, rather
    // than an assumption about what a reasonable format might be.

    @Test("A role outside author/narrator is rejected, matching the contract's own malformed test vector")
    func unknownRoleRejected() {
        #expect(ContributorIdentity(mood: "translator:audible:B00G0WYW92 = Someone") == nil)
    }

    @Test("An openlibrary contributor ID must end in A, not W — a work ID's own suffix is not a contributor's")
    func openLibraryContributorMustEndInA() {
        #expect(ContributorIdentity(mood: "author:openlibrary:OL123W = Someone") == nil)
        #expect(ContributorIdentity(mood: "author:openlibrary:OL123A = Someone") != nil)
    }

    @Test("An Audible contributor ID must be exactly ten uppercase-alphanumeric characters")
    func audibleContributorIDShape() {
        #expect(ContributorIdentity(mood: "author:audible:B00G0WYW92 = Andy Weir") != nil)
        #expect(ContributorIdentity(mood: "author:audible:tooshort = Andy Weir") == nil)
        #expect(ContributorIdentity(mood: "author:audible:b00g0wyw92 = Andy Weir") == nil)
    }

    @Test("A LibriVox contributor ID must not start with zero")
    func libriVoxContributorIDShape() {
        #expect(ContributorIdentity(mood: "narrator:librivox:20 = Ray Example") != nil)
        #expect(ContributorIdentity(mood: "narrator:librivox:020 = Ray Example") == nil)
    }

    @Test("A source outside the contract's four is rejected")
    func unknownSourceRejected() {
        #expect(ContributorIdentity(mood: "author:goodreads:123 = Someone") == nil)
    }

    /// `name` is the fourth source, and was missing.
    ///
    /// The contract's `source_identifier_regex` lists four; this accepted
    /// three, so every `name:` identifier was rejected as malformed. On a real
    /// library that is most narrator credits — a narrator rarely has an
    /// Audible or LibriVox page of their own — and a twelve-narrator recording
    /// sent twelve of them and had all twelve dropped.
    @Test("A name contributor ID is sixteen lowercase hex digits")
    func nameContributorIDShape() {
        let real = ContributorIdentity(mood: "narrator:name:843d303c74d34459 = Scott Brick")
        #expect(real?.displayName == "Scott Brick")
        #expect(real?.role == "narrator")
        #expect(real?.key == "spokenmeta:contributor:narrator:name:843d303c74d34459")

        // Fifteen, seventeen, uppercase and non-hex are all malformed.
        #expect(ContributorIdentity(mood: "narrator:name:843d303c74d3445 = Scott Brick") == nil)
        #expect(ContributorIdentity(mood: "narrator:name:843d303c74d344590 = Scott Brick") == nil)
        #expect(ContributorIdentity(mood: "narrator:name:843D303C74D34459 = Scott Brick") == nil)
        #expect(ContributorIdentity(mood: "narrator:name:843d303c74d344zz = Scott Brick") == nil)
    }

    /// The distinction the contract draws between its own sources.
    ///
    /// A `name:` identifier is a hash of the display name, which makes it
    /// stable but leaves it saying nothing about who the person is — the
    /// contract calls it a deterministic fallback rather than an authoritative
    /// person id. Everything else has a catalogue behind it.
    @Test("Only a name identity is not provider-backed")
    func providerBackedSources() {
        #expect(ContributorIdentity(mood: "narrator:audible:B00G0WYW92 = A")?.isProviderBacked == true)
        #expect(ContributorIdentity(mood: "narrator:librivox:20 = B")?.isProviderBacked == true)
        #expect(ContributorIdentity(mood: "author:openlibrary:OL1A = C")?.isProviderBacked == true)
        #expect(ContributorIdentity(mood: "narrator:name:843d303c74d34459 = D")?.isProviderBacked == false)
    }

    /// The store keeps the key string rather than the parsed value, so the
    /// same question has to be answerable from the key alone.
    @Test("Provider-backing reads out of a stored canonical key")
    func providerBackedFromKey() {
        #expect(ContributorIdentity.isProviderBacked(
            key: "spokenmeta:contributor:narrator:audible:B00G0WYW92"
        ))
        #expect(!ContributorIdentity.isProviderBacked(
            key: "spokenmeta:contributor:narrator:name:843d303c74d34459"
        ))
        // An unparseable key is not evidence of a provider.
        #expect(!ContributorIdentity.isProviderBacked(key: "nonsense"))
    }

    /// `name` is narrator-only.
    ///
    /// It is a fingerprint of a narrator's normalized display name, emitted
    /// when a catalogue names a narrator but has no identifier for them. An
    /// author either has a provider behind them or has no contributor identity
    /// at all, so the agent does not emit `author:name:` and this does not
    /// accept it.
    @Test("The name source is rejected for an author")
    func nameSourceIsNarratorOnly() {
        #expect(ContributorIdentity(mood: "narrator:name:843d303c74d34459 = A") != nil)
        #expect(ContributorIdentity(mood: "author:name:843d303c74d34459 = A") == nil)
    }
}
