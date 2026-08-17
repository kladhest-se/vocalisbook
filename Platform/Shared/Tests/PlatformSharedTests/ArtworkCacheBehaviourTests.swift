import Foundation
import os
import Testing
@testable import PlatformShared

/// The disk half of the cover cache.
///
/// The keys were tested when this was written; the behaviour was not, because
/// the directory was a hardcoded Application Support path and the fetch went
/// straight to `URLSession`. Both are injectable now, which is the whole reason
/// these can exist — none of these decisions need a network to exercise.
///
/// This matters more than a cover cache usually would: offline mode narrows the
/// library to books that will play without a connection, and then has to draw
/// them. A cache that misses is a grid of grey squares at exactly the moment the
/// app claims to work offline.
@Suite("Artwork cache")
struct ArtworkCacheBehaviourTests {

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocalisbook-artwork-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private let url = URL(string: "https://server/photo/:/transcode?url=/thumb&X-Plex-Token=secret")!

    @Test("A cover is fetched once and served from disk after that")
    func secondReadDoesNotFetch() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fetches = Counter()
        let cache = ArtworkCache(directory: directory) { _ in
            fetches.bump()
            return Data("cover".utf8)
        }

        let first = await cache.data(forThumb: "/thumb", width: 400, height: 400, url: url)
        let second = await cache.data(forThumb: "/thumb", width: 400, height: 400, url: url)

        #expect(first == Data("cover".utf8))
        #expect(second == first)
        #expect(fetches.count == 1)
    }

    /// The rule that matters offline: caching a failure would mean a cover that
    /// never returns even after the network does.
    @Test("A failed fetch is not written to disk")
    func failureIsNotCached() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fetches = Counter()
        let cache = ArtworkCache(directory: directory) { _ in
            fetches.bump()
            return nil
        }

        _ = await cache.data(forThumb: "/thumb", width: 400, height: 400, url: url)
        _ = await cache.data(forThumb: "/thumb", width: 400, height: 400, url: url)

        // Tried again rather than remembering the failure.
        #expect(fetches.count == 2)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.isEmpty)
    }

    /// Offline, with no URL to fetch from, a cached cover must still appear —
    /// this is the entire point of the cache.
    @Test("A cached cover is served with no URL at all")
    func cachedCoverSurvivesWithoutAURL() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkCache(directory: directory) { _ in Data("cover".utf8) }
        _ = await cache.data(forThumb: "/thumb", width: 400, height: 400, url: url)

        let offline = await cache.data(forThumb: "/thumb", width: 400, height: 400, url: nil)
        #expect(offline == Data("cover".utf8))
    }

    @Test("An uncached cover with no URL is nil rather than a crash")
    func uncachedWithoutURL() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkCache(directory: directory) { _ in Data("cover".utf8) }
        let result = await cache.data(forThumb: "/missing", width: 400, height: 400, url: nil)
        #expect(result == nil)
    }

    /// Nothing written to disk may carry the account token, and the fetch URL
    /// does carry one.
    @Test("No filename contains the token from the URL")
    func filenamesCarryNoToken() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkCache(directory: directory) { _ in Data("cover".utf8) }
        _ = await cache.data(forThumb: "/thumb", width: 400, height: 400, url: url)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        #expect(files.allSatisfy { !$0.contains("secret") })
    }

    /// Least recently used goes first. Pruning by name or by age-of-creation
    /// would throw away the cover of the book being read right now.
    @Test("Pruning removes the least recently used first")
    func pruneEvictsByAccess() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data(repeating: 0x41, count: 1_000)
        let cache = ArtworkCache(directory: directory) { _ in payload }

        for index in 0..<5 {
            _ = await cache.data(
                forThumb: "/thumb\(index)", width: 400, height: 400, url: url
            )
            // Distinct access times, which is what the sweep orders on.
            try setAccessDate(
                Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                on: directory.appendingPathComponent(
                    ArtworkCache.key(thumb: "/thumb\(index)", width: 400, height: 400)
                )
            )
        }

        // Room for two of the five.
        await cache.prune(maxBytes: 2_400)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.count == 2)
        // The two most recently touched.
        #expect(left.contains { $0.contains("thumb4") })
        #expect(left.contains { $0.contains("thumb3") })
    }

    @Test("Pruning under the limit removes nothing")
    func pruneUnderLimitKeepsEverything() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkCache(directory: directory) { _ in Data(repeating: 0x41, count: 10) }
        for index in 0..<3 {
            _ = await cache.data(forThumb: "/thumb\(index)", width: 400, height: 400, url: url)
        }

        await cache.prune(maxBytes: 1_000_000)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.count == 3)
    }

    private func setAccessDate(_ date: Date, on file: URL) throws {
        var values = URLResourceValues()
        values.contentAccessDate = date
        var mutable = file
        try mutable.setResourceValues(values)
    }
}

/// Counts fetches across the actor boundary. `OSAllocatedUnfairLock`, never
/// `NSLock` — see the note in tests/README.md.
private final class Counter: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    func bump() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
