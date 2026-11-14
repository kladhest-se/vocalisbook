import Foundation
import Testing
@testable import PlatformShared

@Suite("Actual playback and server-scoped covers")
struct FollowupPlatformTests {
    @Test("Buffering, duplicate play and failure pauses bracket only actual listening")
    func listeningTransitions() {
        var gate = ListeningPlaybackGate()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func update(isPlaying: Bool, now: Date) -> ListeningPlaybackGate.Event { gate.update(isPlaying: isPlaying, now: now) }
        func due(now: Date) -> Bool { gate.checkpointDue(now: now) }
        #expect(update(isPlaying: false, now: start) == .unchanged)
        #expect(!due(now: start.addingTimeInterval(20)))
        #expect(update(isPlaying: true, now: start) == .started)
        #expect(update(isPlaying: true, now: start.addingTimeInterval(1)) == .unchanged)
        #expect(!due(now: start.addingTimeInterval(4)))
        #expect(due(now: start.addingTimeInterval(5)))
        #expect(!due(now: start.addingTimeInterval(6)))
        #expect(update(isPlaying: false, now: start.addingTimeInterval(10)) == .ended)
        #expect(update(isPlaying: false, now: start.addingTimeInterval(11)) == .unchanged)
        #expect(!due(now: start.addingTimeInterval(100)))
        #expect(update(isPlaying: true, now: start.addingTimeInterval(100)) == .started)
        #expect(!due(now: start.addingTimeInterval(104)))
        #expect(due(now: start.addingTimeInterval(105)))
    }

    @Test("Reused cover paths cannot read another server's cached bytes")
    func serverIsolation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkCache(directory: dir) { url in Data((url.host ?? "unknown").utf8) }
        let a = await cache.data(forThumb: "/same/thumb", serverIdentifier: "A", width: 400, height: 400, url: URL(string: "https://a.example"))
        let missingB = await cache.data(forThumb: "/same/thumb", serverIdentifier: "B", width: 400, height: 400, url: nil)
        let b = await cache.data(forThumb: "/same/thumb", serverIdentifier: "B", width: 400, height: 400, url: URL(string: "https://b.example"))
        let offlineA = await cache.data(forThumb: "/same/thumb", serverIdentifier: "A", width: 400, height: 400, url: nil)
        #expect(a == Data("a.example".utf8) && b == Data("b.example".utf8))
        #expect(missingB == nil && offlineA == a)
    }

    @Test("Punctuation differences are not collapsed by cover filename sanitization")
    func originalPathsAreHashed() {
        let a = ArtworkCache.key(serverIdentifier: "A", thumb: "/a/b", width: 400, height: 400)
        let b = ArtworkCache.key(serverIdentifier: "A", thumb: "/a_b", width: 400, height: 400)
        #expect(a != b)
    }
}
