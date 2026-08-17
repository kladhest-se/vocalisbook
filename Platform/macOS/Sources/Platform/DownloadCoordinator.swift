import Foundation
import Audiobooks

/// Offline downloads.
///
/// On macOS this is less about being offline and more about not re-streaming a
/// 900 MB file every session, so eviction defaults are more generous than on
/// iOS. The protocol is otherwise identical.
public protocol DownloadCoordinator: Sendable {
    func download(segment: BookTimeline.Segment, from url: URL) async throws
    func localURL(forPartCacheKey key: String) -> URL?
    func evict(partCacheKey: String) async
    func totalBytesOnDisk() async -> Int64
}
