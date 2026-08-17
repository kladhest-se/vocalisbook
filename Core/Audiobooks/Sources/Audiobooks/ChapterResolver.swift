import Foundation
import PlexKit

/// Turns whatever chapter information is available into one book-absolute list.
///
/// Three tiers, first hit wins:
///
/// 1. Plex's own chapter data, when the server analysed the file and the
///    request asked for it. Free, no file access.
/// 2. Chapters embedded in the file, read by the platform. On Apple this is
///    `AVAssetChapterMetadataGroup` over a range request, which is why this
///    package needs no FFmpeg.
/// 3. Track boundaries. Correct for multi-file books, and the only sensible
///    answer for a single-file m4b with no chapter atoms.
///
/// The resolved tier is stored on each chapter so a list built from a weaker
/// source can be upgraded later without reparsing everything.
public enum ChapterResolver {

    /// Tier 1. Converts track-relative Plex offsets to book-absolute ones.
    ///
    /// Returns nil rather than an empty array when no track carried chapters,
    /// so the caller can fall through to tier 2 instead of caching an empty
    /// list as if it were an answer.
    public static func fromPlex(tracks: [PlexTrack]) -> [Chapter]? {
        guard tracks.contains(where: { !$0.chapters.isEmpty }) else { return nil }

        var chapters: [Chapter] = []
        var trackStart = 0

        for track in tracks {
            let duration = track.durationMs ?? 0
            for plexChapter in track.chapters.sorted(by: { $0.startMs < $1.startMs }) {
                chapters.append(
                    Chapter(
                        index: chapters.count,
                        title: plexChapter.tag ?? "Chapter \(chapters.count + 1)",
                        startMs: trackStart + plexChapter.startMs,
                        endMs: trackStart + plexChapter.endMs,
                        source: .plexMetadata
                    )
                )
            }
            trackStart += duration
        }
        return chapters.isEmpty ? nil : chapters
    }

    /// Tier 2. Offsets arrive already relative to their own track, so the
    /// caller supplies which segment each list belongs to.
    ///
    /// The platform reads the file; this package only does the arithmetic,
    /// which keeps `AVFoundation` out of core.
    public static func fromEmbedded(
        perSegment: [(segmentIndex: Int, chapters: [(title: String, startMs: Int, endMs: Int)])],
        segments: [BookTimeline.Segment]
    ) -> [Chapter]? {
        var chapters: [Chapter] = []
        for entry in perSegment.sorted(by: { $0.segmentIndex < $1.segmentIndex }) {
            guard segments.indices.contains(entry.segmentIndex) else { continue }
            let offset = segments[entry.segmentIndex].startMs
            for chapter in entry.chapters {
                chapters.append(
                    Chapter(
                        index: chapters.count,
                        title: chapter.title,
                        startMs: offset + chapter.startMs,
                        endMs: offset + chapter.endMs,
                        source: .embeddedInFile
                    )
                )
            }
        }
        return chapters.isEmpty ? nil : chapters
    }

    /// Tier 3. Always succeeds, which is why it is last.
    public static func fromTrackBoundaries(segments: [BookTimeline.Segment]) -> [Chapter] {
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

    /// Whether a newly available list is worth replacing a cached one with.
    /// Only upgrades — a cached Plex list is never downgraded to track
    /// boundaries because the server happened to omit chapters on one refresh.
    public static func shouldReplace(cached: Chapter.Source?, with candidate: Chapter.Source) -> Bool {
        guard let cached else { return true }
        return rank(candidate) < rank(cached)
    }

    private static func rank(_ source: Chapter.Source) -> Int {
        switch source {
        case .plexMetadata: 0
        case .embeddedInFile: 1
        case .trackBoundary: 2
        }
    }
}
