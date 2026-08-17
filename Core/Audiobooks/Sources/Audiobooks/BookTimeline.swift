import Foundation
import PlexKit

/// Maps between a book-absolute position and the (track, offset) pair every
/// other layer needs.
///
/// This is the load-bearing abstraction of the whole app. A one-file m4b and a
/// ninety-file mp3 rip must be indistinguishable to the player, the scrubber,
/// the bookmark list and the sync engine — all of which speak only in absolute
/// milliseconds from the start of the book. Nothing above this type is allowed
/// to know that tracks exist.
public struct BookTimeline: Sendable, Hashable {

    public struct Segment: Sendable, Hashable {
        public let trackRatingKey: String
        public let trackKey: String
        public let partID: String
        /// Full Plex path to the file, e.g. `/library/parts/55/1700000000/f.m4b`.
        /// Stored so a stream URL can be built from cache without re-fetching
        /// the track from the server.
        public let partKey: String
        public let partCacheKey: String
        public let title: String
        /// Absolute offset of this track's first frame within the book.
        public let startMs: Int
        public let durationMs: Int

        public var endMs: Int { startMs + durationMs }

        public init(
            trackRatingKey: String,
            trackKey: String,
            partID: String,
            partKey: String,
            partCacheKey: String,
            title: String,
            startMs: Int,
            durationMs: Int
        ) {
            self.trackRatingKey = trackRatingKey
            self.trackKey = trackKey
            self.partID = partID
            self.partKey = partKey
            self.partCacheKey = partCacheKey
            self.title = title
            self.startMs = startMs
            self.durationMs = durationMs
        }
    }

    public struct Position: Sendable, Hashable {
        public let segmentIndex: Int
        public let offsetInSegmentMs: Int
        public let absoluteMs: Int

        public init(segmentIndex: Int, offsetInSegmentMs: Int, absoluteMs: Int) {
            self.segmentIndex = segmentIndex
            self.offsetInSegmentMs = offsetInSegmentMs
            self.absoluteMs = absoluteMs
        }
    }

    public let bookRatingKey: String
    public let segments: [Segment]
    public let chapters: [Chapter]
    public let totalDurationMs: Int

    /// Builds a timeline from ordered tracks.
    ///
    /// Tracks with no duration are skipped rather than assumed to be zero
    /// length: a missing duration means Plex has not finished analysing the
    /// file, and including it would silently corrupt every absolute position
    /// after it. The caller should treat a short timeline as "not ready yet"
    /// and re-fetch, not as a complete book.
    public init(bookRatingKey: String, tracks: [PlexTrack], chapters: [Chapter] = []) {
        self.bookRatingKey = bookRatingKey

        var cursor = 0
        var built: [Segment] = []
        for track in tracks {
            guard let duration = track.durationMs, duration > 0,
                  let part = track.primaryPart else { continue }
            built.append(
                Segment(
                    trackRatingKey: track.ratingKey,
                    trackKey: track.key,
                    partID: part.id,
                    partKey: part.key,
                    partCacheKey: part.cacheKey,
                    title: track.title,
                    startMs: cursor,
                    durationMs: duration
                )
            )
            cursor += duration
        }
        self.segments = built
        self.totalDurationMs = cursor
        self.chapters = chapters.isEmpty ? Self.chaptersFromSegments(built) : chapters
    }

    /// Rebuilds a timeline from already-computed segments.
    ///
    /// Used when loading from cache, where the offsets were computed once at
    /// cache time and read back rather than recalculated. Trusts the offsets it
    /// is given — `CachedTimeline.isConsistent` is the check for that.
    public init(bookRatingKey: String, segments: [Segment], chapters: [Chapter]) {
        self.bookRatingKey = bookRatingKey
        self.segments = segments
        self.totalDurationMs = segments.last?.endMs ?? 0
        self.chapters = chapters.isEmpty ? Self.chaptersFromSegments(segments) : chapters
    }

    public var isComplete: Bool { !segments.isEmpty }

    /// Absolute milliseconds to a concrete track and offset.
    ///
    /// Clamps rather than traps. Positions arriving from Plex, from CloudKit or
    /// from an older version of the app can legitimately exceed the current
    /// duration when a book has been re-ripped, and losing someone's place is a
    /// far worse outcome than seeking to the end.
    public func locate(absoluteMs: Int) -> Position? {
        guard isComplete else { return nil }
        let clamped = min(max(absoluteMs, 0), max(totalDurationMs - 1, 0))

        var low = 0
        var high = segments.count - 1
        while low < high {
            let mid = (low + high) / 2
            if clamped < segments[mid].endMs { high = mid } else { low = mid + 1 }
        }
        return Position(
            segmentIndex: low,
            offsetInSegmentMs: clamped - segments[low].startMs,
            absoluteMs: clamped
        )
    }

    /// The inverse, used when a position arrives from the audio engine.
    public func absolute(segmentIndex: Int, offsetInSegmentMs: Int) -> Int? {
        guard segments.indices.contains(segmentIndex) else { return nil }
        return segments[segmentIndex].startMs + offsetInSegmentMs
    }

    public func chapter(at absoluteMs: Int) -> Chapter? {
        chapters.last { $0.startMs <= absoluteMs }
    }

    private static func chaptersFromSegments(_ segments: [Segment]) -> [Chapter] {
        segments.enumerated().map { index, segment in
            Chapter(
                index: index,
                title: segment.title,
                startMs: segment.startMs,
                endMs: segment.endMs,
                source: .trackBoundary
            )
        }
    }
}

public struct Chapter: Sendable, Hashable, Identifiable {
    /// Where the chapter list came from, in descending order of trust. Stored
    /// alongside the chapters so a cached list from a weaker source can be
    /// upgraded later without re-parsing everything.
    public enum Source: String, Sendable, Codable {
        case plexMetadata
        case embeddedInFile
        case trackBoundary
    }

    public let index: Int
    public let title: String
    public let startMs: Int
    public let endMs: Int
    public let source: Source

    public var id: Int { index }
    public var durationMs: Int { endMs - startMs }

    public init(index: Int, title: String, startMs: Int, endMs: Int, source: Source) {
        self.index = index
        self.title = title
        self.startMs = startMs
        self.endMs = endMs
        self.source = source
    }
}
