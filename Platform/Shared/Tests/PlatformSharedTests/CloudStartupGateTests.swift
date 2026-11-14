import Foundation
import Testing
import Audiobooks
@testable import PlatformShared

@MainActor @Suite("Cloud enabling preserves local data")
struct CloudStartupGateTests {
    private func settings() -> (UserDefaults, String) {
        let name = "VocalisBookTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
    @Test("No iCloud account is a normal exit and the following attempt can start")
    func unavailableThenAvailable() async {
        let (defaults, name) = settings()
        defer { defaults.removePersistentDomain(forName: name) }
        var started = false
        let first = await CloudStartupGate.run(defaults: defaults, key: "startup",
            isAvailable: { false }, start: { started = true })
        #expect(first == .unavailable && !started)
        #expect(!defaults.bool(forKey: "startup"))
        let second = await CloudStartupGate.run(defaults: defaults, key: "startup",
            isAvailable: { true }, start: { started = true; #expect(defaults.bool(forKey: "startup")) })
        #expect(second == .started && started)
        #expect(!defaults.bool(forKey: "startup"))
    }
    @Test("A real interrupted startup is held back once, without leaving a stuck flag")
    func interruptedStartup() async {
        let (defaults, name) = settings()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "startup")
        let result = await CloudStartupGate.run(defaults: defaults, key: "startup",
            isAvailable: { Issue.record("Availability should not be checked"); return true },
            start: { Issue.record("Interrupted startup must be held back") })
        #expect(result == .heldBack)
        #expect(!defaults.bool(forKey: "startup"))
    }
    @Test("Offline-only bookmarks survive account unavailability and merge with cloud records")
    func retainsAndMergesListeningData() async throws {
        let (defaults, name) = settings()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = try AudiobookDatabase.inMemory()
        let bookmarks = BookmarkStore(database: db), cloud = CloudSyncStore(database: db)
        let local = try bookmarks.add(bookRatingKey: "900", absoluteMs: 100, label: "Offline-only")
        _ = await CloudStartupGate.run(defaults: defaults, key: "startup", isAvailable: { false }, start: {})
        #expect(try bookmarks.bookmarks(bookRatingKey: "900").first?.id == local.id)
        _ = await CloudStartupGate.run(defaults: defaults, key: "startup", isAvailable: { true }, start: {
            do {
                try cloud.apply([CloudRecord(kind: .bookmark, id: "remote", revision: 1,
                    fields: ["bookRatingKey": .string("900"), "absoluteMs": .int(200)])])
            } catch { Issue.record(error) }
        })
        #expect(try bookmarks.bookmarks(bookRatingKey: "900").count == 2)
        #expect(try cloud.pendingChanges().contains { $0.id == local.id })
    }
    @Test("Cancellation clears the startup marker without starting the engine")
    func cancellation() async {
        let (defaults, name) = settings()
        defer { defaults.removePersistentDomain(forName: name) }
        let outcome = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await CloudStartupGate.run(defaults: defaults, key: "startup", isAvailable: { true },
                start: { Issue.record("Cancelled startup must not run") })
        }.value
        #expect(outcome == .unavailable)
        #expect(!defaults.bool(forKey: "startup"))
    }
}
