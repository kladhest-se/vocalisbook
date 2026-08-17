import Foundation
import Testing
@testable import PlatformShared

/// The key is the part worth testing.
///
/// The fetching is a `URLSession` call and the storage is `Data.write`; neither
/// is interesting. What is interesting is what ends up in the filename, because
/// a Plex artwork URL carries `X-Plex-Token` in its query string and the obvious
/// implementation — sanitise the URL, use it as the name — writes the account
/// token to disk in a directory that outlives the session.
@Suite("Artwork cache keys")
struct ArtworkCacheTests {

    private let thumb = "/library/metadata/900/thumb/1700000000"

    @Test("A key is safe to use as a filename")
    func keysAreFilenameSafe() {
        let key = ArtworkCache.key(thumb: thumb, width: 600, height: 600)

        #expect(!key.contains("/"))
        #expect(!key.contains(":"))
        #expect(!key.contains("?"))
        #expect(!key.isEmpty)
    }

    /// The one that matters.
    @Test("A token never reaches the key")
    func tokensAreNotInKeys() {
        // The token lives in the URL, not the thumb — so a key derived from the
        // thumb cannot contain one. Asserted rather than assumed, because the
        // tempting refactor is to pass the URL in and derive everything from it.
        let key = ArtworkCache.key(thumb: thumb, width: 600, height: 600)

        #expect(!key.lowercased().contains("token"))
        #expect(!key.contains("xplex"))
    }

    @Test("Sizes are part of the identity")
    func sizeDistinguishes() {
        let small = ArtworkCache.key(thumb: thumb, width: 200, height: 200)
        let large = ArtworkCache.key(thumb: thumb, width: 600, height: 600)

        #expect(small != large)
    }

    @Test("Different covers get different keys")
    func thumbsDistinguish() {
        let one = ArtworkCache.key(thumb: "/library/metadata/900/thumb/1", width: 600, height: 600)
        let two = ArtworkCache.key(thumb: "/library/metadata/901/thumb/1", width: 600, height: 600)

        #expect(one != two)
    }

    /// A cache that misses on every launch grows forever and never helps.
    @Test("A key is stable across calls")
    func keysAreStable() {
        let first = ArtworkCache.key(thumb: thumb, width: 600, height: 600)
        let second = ArtworkCache.key(thumb: thumb, width: 600, height: 600)

        #expect(first == second)
    }

    /// Plex thumb paths are short, but nothing guarantees it, and a filename
    /// past the limit fails the write rather than the lookup — so the cover
    /// simply never caches and nothing says why.
    @Test("A very long thumb still produces a usable filename")
    func longThumbsAreShortened() {
        let long = "/library/metadata/" + String(repeating: "a", count: 500) + "/thumb/1"
        let key = ArtworkCache.key(thumb: long, width: 600, height: 600)

        #expect(key.count < 128)
        // Still distinct from another long one sharing its tail.
        let other = "/library/metadata/" + String(repeating: "b", count: 500) + "/thumb/1"
        #expect(key != ArtworkCache.key(thumb: other, width: 600, height: 600))
    }
}
