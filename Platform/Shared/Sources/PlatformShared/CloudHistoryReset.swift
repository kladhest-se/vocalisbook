import Foundation

/// The local copy is removed only after both remote operations succeeded.
/// Each step is injected so failure/retry ordering is testable without iCloud.
enum CloudHistoryReset {
    static func perform(
        deleteZone: @Sendable () async throws -> Void,
        recreateZone: @Sendable () async throws -> Void,
        clearLocal: @Sendable () throws -> Void
    ) async throws {
        try await deleteZone()
        try await recreateZone()
        try clearLocal()
    }
}
