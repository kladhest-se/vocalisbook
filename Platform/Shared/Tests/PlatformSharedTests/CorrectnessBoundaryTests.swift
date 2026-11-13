import Foundation
import Testing
@testable import PlatformShared

private final class ResetSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

@Suite("Confirmed cloud history reset")
struct CloudHistoryResetTests {
    enum Failure: Error { case offline }

    @Test("A failed remote delete preserves local data and can be retried")
    func deleteFailureAndRetry() async throws {
        let steps = ResetSteps()
        do {
            try await CloudHistoryReset.perform(
                deleteZone: { steps.append("delete-failed"); throw Failure.offline },
                recreateZone: { steps.append("create") }, clearLocal: { steps.append("local") }
            )
            Issue.record("An unconfirmed deletion must throw")
        } catch Failure.offline {}
        #expect(steps.values == ["delete-failed"])
        try await CloudHistoryReset.perform(
            deleteZone: { steps.append("delete") }, recreateZone: { steps.append("create") },
            clearLocal: { steps.append("local") }
        )
        #expect(steps.values == ["delete-failed", "delete", "create", "local"])
    }

    @Test("Failed zone recreation cannot clear local history")
    func recreationFailure() async throws {
        let steps = ResetSteps()
        do {
            try await CloudHistoryReset.perform(
                deleteZone: { steps.append("delete") },
                recreateZone: { steps.append("create-failed"); throw Failure.offline },
                clearLocal: { steps.append("local") }
            )
            Issue.record("Failed recreation must throw")
        } catch Failure.offline {}
        #expect(steps.values == ["delete", "create-failed"])
    }
}

private final class FakeTransfers: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: String] = [:]
    private var nextID = 1
    private var starts = 0
    func start(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        tasks[nextID] = key; nextID += 1; starts += 1
    }
    private func cancel(_ id: Int) {
        lock.lock(); defer { lock.unlock() }; tasks[id] = nil
    }
    func snapshot() -> [DownloadTransferQueue.Transfer] {
        lock.lock(); defer { lock.unlock() }
        return tasks.map { id, key in
            DownloadTransferQueue.Transfer(key: key, id: id, isActive: true,
                                           cancel: { self.cancel(id) })
        }
    }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
}

@MainActor @Suite("Download cancellation and duplicate prevention")
struct DownloadTransferQueueTests {
    @Test("Repeated scheduling reuses active transfers, including restored tasks")
    func duplicateAndRestoredTasks() async {
        let tasks = FakeTransfers(), gate = DownloadTaskGate()
        tasks.start("restored")
        let queue = DownloadTransferQueue(gate: gate, snapshot: { tasks.snapshot() })
        queue.enqueue(keys: ["restored", "new", "new"]) { tasks.start($0) }
        queue.enqueue(keys: ["restored", "new"]) { tasks.start($0) }
        await queue.waitUntilIdle()
        #expect(tasks.startCount == 2)
    }

    @Test("Removal cancels the selected active tasks and permits a new attempt")
    func cancelAndRetry() async {
        let tasks = FakeTransfers(), gate = DownloadTaskGate()
        let queue = DownloadTransferQueue(gate: gate, snapshot: { tasks.snapshot() })
        queue.enqueue(keys: ["a", "b"]) { tasks.start($0) }
        await queue.waitUntilIdle()
        queue.cancel(keys: ["a"])
        await queue.waitUntilIdle()
        #expect(Set(tasks.snapshot().compactMap(\.key)) == ["b"])
        queue.enqueue(keys: ["a"]) { tasks.start($0) }
        await queue.waitUntilIdle()
        #expect(tasks.startCount == 3)
        queue.cancel(keys: ["a", "b"])
        await queue.waitUntilIdle()
        #expect(tasks.snapshot().isEmpty)
    }

    @Test("Removing a queued download invalidates its older scheduled start")
    func removalBeforeEnumeration() async {
        let tasks = FakeTransfers(), gate = DownloadTaskGate()
        let queue = DownloadTransferQueue(gate: gate, snapshot: { tasks.snapshot() })
        queue.enqueue(keys: ["a"]) { tasks.start($0) }
        queue.cancel(keys: ["a"])
        queue.enqueue(keys: ["a"]) { tasks.start($0) }
        await queue.waitUntilIdle()
        #expect(tasks.startCount == 1)
    }

    @Test("Remove all cancels restored orphan transfers too")
    func removeAllRestoredTasks() async {
        let tasks = FakeTransfers(), gate = DownloadTaskGate()
        tasks.start("orphan")
        let queue = DownloadTransferQueue(gate: gate, snapshot: { tasks.snapshot() })
        queue.enqueue(keys: ["queued-before-removal"]) { tasks.start($0) }
        queue.cancelAll(knownKeys: [])
        queue.enqueue(keys: ["orphan"]) { tasks.start($0) }
        await queue.waitUntilIdle()
        #expect(tasks.startCount == 2)
        #expect(tasks.snapshot().compactMap(\.key) == ["orphan"])
    }

    @Test("Cancelled callbacks cannot alter a newly retried download")
    func staleCallbacks() {
        let gate = DownloadTaskGate()
        var writes = 0
        gate.register(id: 1, key: "a")
        gate.invalidate(["a"])
        #expect(!gate.performIfCurrent(id: 1, key: "a") { writes += 1 })
        gate.register(id: 2, key: "a")
        #expect(!gate.performIfCurrent(id: 1, key: "a") { writes += 1 })
        #expect(gate.performIfCurrent(id: 2, key: "a") { writes += 1 })
        #expect(writes == 1)
    }
}
