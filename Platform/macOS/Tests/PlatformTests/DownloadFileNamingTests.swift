import Foundation
import Testing
@testable import Platform

/// The first tests in the platform layer.
///
/// There were none, across all three packages, while Core had well over a
/// hundred — and the player, the download coordinator and the Now Playing
/// reporter all live here. This is the thin end of that.
///
/// They run from `Platform/macOS` because it is the only one of the three
/// `swift test` can run: iOS and tvOS build against a generic simulator
/// destination with nothing booted. `drift.sh` asserts the files under test are
/// byte-identical across the copies, so testing one is testing all three — which
/// is worth more than the duplication costs, and is the first thing that
/// duplication has ever paid for.
@Suite("Downloaded file naming")
struct DownloadFileNamingTests {

    /// The bug this logic exists because of.
    ///
    /// Files were stored as `<cacheKey>.audio`, and `.audio` is not an extension
    /// anything recognises. For a local file `AVURLAsset` has no `Content-Type`
    /// to fall back on and infers the container from the extension, so the item
    /// never loaded — a downloaded book that silently would not play, while
    /// streaming the same book worked.
    @Test("The real extension comes from the part path")
    func extensionFromPath() {
        #expect(
            DownloadFileNaming.fileExtension(
                forPath: "/library/parts/55/1700000000/book.m4b",
                mimeType: nil
            ) == "m4b"
        )
    }

    @Test("Case is normalised, because a filename is not")
    func extensionIsLowercased() {
        #expect(
            DownloadFileNaming.fileExtension(forPath: "/library/parts/55/1/BOOK.M4B", mimeType: nil)
                == "m4b"
        )
    }

    @Test("A path with no extension falls back to the response type")
    func mimeTypeFallback() {
        #expect(
            DownloadFileNaming.fileExtension(forPath: "/library/parts/55/1/file", mimeType: "audio/mpeg")
                == "mp3"
        )
    }

    @Test("No path at all still uses the response type")
    func mimeTypeWithoutPath() {
        #expect(DownloadFileNaming.fileExtension(forPath: nil, mimeType: "audio/mpeg") == "mp3")
    }

    /// A guess, and deliberately so: audiobooks are overwhelmingly m4b, and a
    /// wrong extension is no worse than the unrecognised one this replaced.
    @Test("Nothing to go on gives a plausible default rather than none")
    func lastResort() {
        #expect(DownloadFileNaming.fileExtension(forPath: nil, mimeType: nil) == "m4b")
        #expect(DownloadFileNaming.fileExtension(forPath: "/library/parts/55/1/f", mimeType: "x/y") == "m4b")
    }

    /// The path wins even when both are present: a server's `Content-Type` on a
    /// range request is less reliable than the filename it is serving.
    @Test("The path is preferred over the response type")
    func pathBeatsMimeType() {
        #expect(
            DownloadFileNaming.fileExtension(
                forPath: "/library/parts/55/1/book.m4b",
                mimeType: "application/octet-stream"
            ) == "m4b"
        )
    }
}
