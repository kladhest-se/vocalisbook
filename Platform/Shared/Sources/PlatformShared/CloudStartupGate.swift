import Foundation

/// A normal unavailable/cancelled attempt must not look like a process crash
/// on the next launch. Only an interrupted process leaves this flag behind.
@MainActor
public enum CloudStartupGate {
    public enum Outcome: Sendable, Equatable { case heldBack, unavailable, started }

    public static func run(
        defaults: UserDefaults, key: String,
        isAvailable: () async -> Bool,
        start: () async -> Void
    ) async -> Outcome {
        if defaults.bool(forKey: key) {
            defaults.removeObject(forKey: key)
            return .heldBack
        }
        defaults.set(true, forKey: key)
        defer { defaults.removeObject(forKey: key) }
        guard await isAvailable(), !Task.isCancelled else { return .unavailable }
        await start()
        return .started
    }
}
