import Foundation
import Testing
import PlexKit
@testable import Audiobooks

@Suite("Timeline")
struct TimelineTests {
    private func segments(_ durations: [Int]) -> [BookTimeline.Segment] {
        var start = 0
        return durations.enumerated().map { index, duration in
            defer { start += duration }
            return BookTimeline.Segment(
                trackRatingKey: "t\(index)",
                trackKey: "/library/metadata/t\(index)",
                partID: "p\(index)",
                partKey: "/library/parts/p\(index)/1700000000/f.mp3",
                partCacheKey: "p\(index)-1700000000",
                title: "Part \(index + 1)",
                startMs: start,
                durationMs: duration
            )
        }
    }

    @Test("An absolute position maps to the right track and offset")
    func locate() {
        let timeline = BookTimeline(
            bookRatingKey: "900",
            segments: segments([600_000, 600_000, 300_000]),
            chapters: []
        )
        let position = timeline.locate(absoluteMs: 750_000)
        #expect(position?.segmentIndex == 1)
        #expect(position?.offsetInSegmentMs == 150_000)
    }

    @Test("Boundaries land on the start of the next track, not the end of the last")
    func locateAtBoundary() {
        let timeline = BookTimeline(
            bookRatingKey: "900",
            segments: segments([600_000, 600_000]),
            chapters: []
        )
        let position = timeline.locate(absoluteMs: 600_000)
        #expect(position?.segmentIndex == 1)
        #expect(position?.offsetInSegmentMs == 0)
    }

    @Test("A stale position past the end clamps rather than trapping")
    func locateClamps() {
        // Happens for real: a book gets re-ripped shorter, and a position from
        // CloudKit or an older build exceeds the new duration. Seeking to the
        // end is a far better outcome than losing someone's place.
        let timeline = BookTimeline(
            bookRatingKey: "900",
            segments: segments([600_000]),
            chapters: []
        )
        let position = timeline.locate(absoluteMs: 99_000_000)
        #expect(position?.segmentIndex == 0)
        #expect(position?.absoluteMs == 599_999)
    }

    @Test("Round-tripping absolute to segment and back is lossless")
    func roundTrip() {
        let timeline = BookTimeline(
            bookRatingKey: "900",
            segments: segments([600_000, 600_000, 300_000]),
            chapters: []
        )
        for absolute in stride(from: 0, to: 1_500_000, by: 7_919) {
            let position = timeline.locate(absoluteMs: absolute)!
            let back = timeline.absolute(
                segmentIndex: position.segmentIndex,
                offsetInSegmentMs: position.offsetInSegmentMs
            )
            #expect(back == absolute)
        }
    }

    @Test("Tracks with no duration are skipped and the book reads as incomplete")
    func incompleteMetadata() throws {
        let json = """
        {"ratingKey":"t0","key":"/k","title":"Part 1",
         "Media":[{"Part":[{"id":"p0","key":"/library/parts/p0/1/f.mp3","updatedAt":1}]}]}
        """
        let track = try JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
        let timeline = BookTimeline(bookRatingKey: "900", tracks: [track])
        #expect(timeline.isComplete == false)
        #expect(timeline.totalDurationMs == 0)
    }
}

@Suite("Chapter resolution")
struct ChapterResolverTests {
    private func track(index: Int, duration: Int, chapters: [(Int, Int, String)]) throws -> PlexTrack {
        let chapterJSON = chapters.map {
            #"{"startTimeOffset":\#($0.0),"endTimeOffset":\#($0.1),"tag":"\#($0.2)"}"#
        }.joined(separator: ",")
        let json = """
        {"ratingKey":"t\(index)","key":"/k","title":"Part \(index + 1)","index":\(index + 1),
         "duration":\(duration),"Chapter":[\(chapterJSON)],
         "Media":[{"Part":[{"id":"p\(index)","key":"/p","updatedAt":1}]}]}
        """
        return try JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
    }

    @Test("Plex chapter offsets are converted from track-relative to book-absolute")
    func plexChaptersBecomeAbsolute() throws {
        let tracks = [
            try track(index: 0, duration: 600_000, chapters: [(0, 300_000, "One"), (300_000, 600_000, "Two")]),
            try track(index: 1, duration: 600_000, chapters: [(0, 600_000, "Three")]),
        ]
        let chapters = try #require(ChapterResolver.fromPlex(tracks: tracks))
        #expect(chapters.map(\.startMs) == [0, 300_000, 600_000])
        #expect(chapters.last?.title == "Three")
        #expect(chapters.allSatisfy { $0.source == .plexMetadata })
    }

    @Test("No chapters anywhere returns nil so the caller falls through a tier")
    func noPlexChaptersIsNil() throws {
        let tracks = [try track(index: 0, duration: 600_000, chapters: [])]
        #expect(ChapterResolver.fromPlex(tracks: tracks) == nil)
    }

    @Test("A cached list is only replaced by a better source, never a worse one")
    func onlyUpgrades() {
        #expect(ChapterResolver.shouldReplace(cached: .trackBoundary, with: .plexMetadata))
        #expect(ChapterResolver.shouldReplace(cached: .trackBoundary, with: .embeddedInFile))
        #expect(ChapterResolver.shouldReplace(cached: .plexMetadata, with: .trackBoundary) == false)
        #expect(ChapterResolver.shouldReplace(cached: nil, with: .trackBoundary))
    }
}
