import Foundation
import Audiobooks

/// Offline downloads.
///
/// Present on iOS and macOS, absent on tvOS. Anything calling into this must
/// be guarded by `PlatformCapabilities.supportsOfflineDownloads` so it does not
/// silently compile into a build that cannot honour it.
public protocol DownloadCoordinator: Sendable {
    func download(segment: BookTimeline.Segment, from url: URL) async throws
    func localURL(forPartCacheKey key: String) -> URL?
    func evict(partCacheKey: String) async
    func totalBytesOnDisk() async -> Int64
}
