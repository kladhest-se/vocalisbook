import AVFoundation
import Foundation

/// Reads the chapters embedded in an audio file.
///
/// Tier 2 of `ChapterResolver`. The core package does the arithmetic and knows
/// nothing about how a file is parsed; this is the half that needs a framework,
/// which is why it lives here and is handed over as a closure. Same seam as
/// `HTTPClient` and `URLSessionHTTPClient`.
///
/// `AVURLAsset` fetches only the ranges it needs, so a remote 900 MB m4b costs a
/// few kilobytes to read the chapter atoms out of — the moov box, not the audio.
/// That is what makes this viable against a streaming URL and why the package
/// needs no FFmpeg.
///
/// The URL must carry its own credentials. `AVURLAsset` cannot be given custom
/// headers, which is the same constraint the player works under and the reason
/// Plex tokens travel in the query string.
public enum EmbeddedChapterReader {

    /// Chapters in one file, with offsets relative to that file.
    ///
    /// Returns an empty list rather than throwing. Every failure here means the
    /// same thing to the caller — no chapters available from this tier, fall
    /// back to what it already had — and a file with no chapter atoms is the
    /// ordinary case, not an error worth propagating.
    public static func chapters(
        at url: URL,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) async -> [(title: String, startMs: Int, endMs: Int)] {
        let asset = AVURLAsset(url: url)

        let groups: [AVTimedMetadataGroup]
        do {
            groups = try await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: preferredLanguages
            )
        } catch {
            return []
        }

        var result: [(title: String, startMs: Int, endMs: Int)] = []
        for group in groups {
            // A range that is indefinite or otherwise not numeric produces NaN
            // out of `seconds`, and `Int(NaN)` traps rather than returning zero.
            // Skipping is right anyway: a chapter with no known start cannot be
            // seeked to.
            let range = group.timeRange
            guard range.start.isNumeric, range.duration.isNumeric else { continue }

            let startMs = Int((range.start.seconds * 1000).rounded())
            let endMs = Int((range.end.seconds * 1000).rounded())
            guard endMs > startMs else { continue }

            result.append((title: await title(of: group), startMs: startMs, endMs: endMs))
        }
        return result
    }

    /// The title item, or the first item that has any string at all.
    ///
    /// Falls back to an empty string, which the caller replaces with a number.
    /// Deciding that here would put presentation in the wrong layer and would
    /// also number each file from one.
    private static func title(of group: AVTimedMetadataGroup) async -> String {
        let items = group.items
        let candidate = items.first { $0.commonKey == .commonKeyTitle } ?? items.first
        guard let candidate else { return "" }
        // `try?` on a throwing call returning `String?` gives `String??`; both
        // levels have to be flattened or the result is a description of an
        // optional rather than the title.
        return ((try? await candidate.load(.stringValue)) ?? nil) ?? ""
    }
}
