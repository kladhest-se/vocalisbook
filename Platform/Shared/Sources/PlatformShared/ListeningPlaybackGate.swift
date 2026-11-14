import Foundation

/// Actual audio transitions bracket history; duplicate transport commands and
/// buffering do not create listening time. Checkpoint cadence is independent of
/// audiobook position, so seeks and playback speed do not affect recovery.
public struct ListeningPlaybackGate: Sendable {
    public enum Event: Sendable, Equatable { case started, ended, unchanged }
    public private(set) var isListening = false
    private var lastCheckpoint: Date?
    public init() {}

    public mutating func update(isPlaying: Bool, now: Date = Date()) -> Event {
        guard isPlaying != isListening else { return .unchanged }
        isListening = isPlaying
        lastCheckpoint = isPlaying ? now : nil
        return isPlaying ? .started : .ended
    }

    public mutating func checkpointDue(now: Date = Date()) -> Bool {
        guard isListening, now.timeIntervalSince(lastCheckpoint ?? now) >= 5 else { return false }
        lastCheckpoint = now
        return true
    }
}
