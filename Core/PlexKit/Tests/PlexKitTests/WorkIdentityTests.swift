import Foundation
import Testing
@testable import PlexKit

/// `WorkIdentity` is deliberately not a case on `BookIdentity` — see its own
/// documentation for why conflating the two would be a correctness bug, not
/// a style one. These tests cover the parser in isolation.
@Suite("Work identity")
struct WorkIdentityTests {

    @Test("A source and identifier become a canonical work key")
    func basicParse() {
        let work = WorkIdentity(mood: "openlibrary:OL12345W")
        #expect(work?.key == "spokenmeta:work:openlibrary:OL12345W")
    }

    @Test("A missing separator is not a work identity")
    func noSeparator() {
        #expect(WorkIdentity(mood: "openlibraryOL12345W") == nil)
    }

    @Test("An empty source is rejected")
    func emptySource() {
        #expect(WorkIdentity(mood: ":OL12345W") == nil)
    }

    @Test("An empty identifier is rejected")
    func emptyIdentifier() {
        #expect(WorkIdentity(mood: "openlibrary:") == nil)
    }

    @Test("Two editions of the same work share a key")
    func sameWorkAcrossEditions() {
        let abridged = WorkIdentity(mood: "openlibrary:OL12345W")
        let unabridged = WorkIdentity(mood: "openlibrary:OL12345W")
        #expect(abridged?.key == unabridged?.key)
    }

    // Matches VocalisMeta's own published contract (metadata-contract-v2.json)
    // and its test vectors directly.

    @Test("A source other than openlibrary is rejected")
    func nonOpenLibrarySourceRejected() {
        #expect(WorkIdentity(mood: "audible:OL12345W") == nil)
    }

    @Test("An identifier ending in M rather than W is rejected, matching the contract's own malformed test vector")
    func wrongSuffixRejected() {
        #expect(WorkIdentity(mood: "openlibrary:OL12345M") == nil)
    }

    @Test("An identifier with no digits between OL and W is rejected")
    func noDigitsRejected() {
        #expect(WorkIdentity(mood: "openlibrary:OLW") == nil)
    }
}
