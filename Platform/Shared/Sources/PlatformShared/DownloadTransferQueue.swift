import Foundation

/// Guards store callbacks against cancelled attempts that finish after a retry.
public final class DownloadTaskGate: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [String: Int] = [:]
    private var generations: [String: Int] = [:]
    private var globalGeneration = 0
    public struct Generation: Sendable, Equatable {
        let global: Int
        let part: Int
    }
    public init() {}
    public func register(id: Int, key: String) {
        lock.lock(); defer { lock.unlock() }
        attempts[key] = id
    }
    public func invalidate(_ keys: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for key in keys {
            attempts[key] = -1
            generations[key, default: 0] += 1
        }
    }
    public func invalidateAll(knownKeys: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        globalGeneration += 1
        for key in knownKeys { attempts[key] = -1 }
    }
    public func blockAttempts(_ keys: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for key in keys { attempts[key] = -1 }
    }
    public func generation(for key: String) -> Generation {
        lock.lock(); defer { lock.unlock() }
        return Generation(global: globalGeneration, part: generations[key, default: 0])
    }
    @discardableResult
    public func performIfCurrent(id: Int, key: String, _ operation: () throws -> Void) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        // No entry yet is a restored task whose first callback beat enumeration.
        guard attempts[key] == id || (attempts[key] == nil && globalGeneration == 0) else { return false }
        try operation()
        return true
    }
}

/// Orders scheduling and cancellation around background-session enumeration.
/// The same path handles tasks restored from a previous process.
@MainActor
public final class DownloadTransferQueue {
    public struct Transfer: Sendable {
        public let key: String?
        public let id: Int
        public let isActive: Bool
        public let cancel: @Sendable () -> Void
        public init(key: String?, id: Int, isActive: Bool, cancel: @escaping @Sendable () -> Void) {
            self.key = key; self.id = id; self.isActive = isActive; self.cancel = cancel
        }
    }
    private let snapshot: @Sendable () async -> [Transfer]
    private let gate: DownloadTaskGate
    private var tail: Task<Void, Never>?
    public init(gate: DownloadTaskGate, snapshot: @escaping @Sendable () async -> [Transfer]) {
        self.gate = gate; self.snapshot = snapshot
    }
    public func enqueue(keys: [String], start: @escaping @MainActor @Sendable (String) -> Void) {
        let generations = Dictionary(keys.map { ($0, gate.generation(for: $0)) }, uniquingKeysWith: { first, _ in first })
        submit {
            let active = Set(await self.snapshot().filter(\.isActive).compactMap(\.key))
            for key in Set(keys) where !active.contains(key) && self.gate.generation(for: key) == generations[key] { start(key) }
        }
    }
    public func cancel(keys: Set<String>) {
        gate.invalidate(keys)
        submit {
            for task in await self.snapshot() where task.key.map(keys.contains) == true {
                task.cancel()
            }
        }
    }
    public func cancelAll(knownKeys: Set<String>) {
        gate.invalidateAll(knownKeys: knownKeys)
        submit {
            let tasks = await self.snapshot()
            self.gate.blockAttempts(Set(tasks.compactMap(\.key)))
            for task in tasks { task.cancel() }
        }
    }
    public func waitUntilIdle() async { await tail?.value }
    private func submit(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await operation() }
    }
}
