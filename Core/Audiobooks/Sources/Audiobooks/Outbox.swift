import Foundation

/// A mutation made locally that has not yet reached Plex.
///
/// Rows are coalesced per (bookID, kind) so an offline session produces one
/// pending position update rather than thousands. `revision` is monotonic per
/// device and is what CloudKit sync compares; `attempts` drives backoff and,
/// past a threshold, a visible "couldn't sync" state rather than silent retry
/// forever.
public struct OutboxEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case position
        case finished
        case unfinished

        /// The instruction this one contradicts, if any.
        ///
        /// Finishing and unfinishing a book are opposites: queueing one while
        /// the other waits would send both, and the server would be told to
        /// scrobble every track and then unscrobble every track.
        ///
        /// A position contradicts nothing — a book can be finished *and* have a
        /// place in it, which is exactly what `markFinished` leaves behind.
        var opposite: Kind? {
            switch self {
            case .finished: .unfinished
            case .unfinished: .finished
            case .position: nil
            }
        }
    }

    public let id: UUID
    public let bookRatingKey: String
    public let kind: Kind
    public let absoluteMs: Int
    public let recordedAt: Date
    public var revision: Int
    public var attempts: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        bookRatingKey: String,
        kind: Kind,
        absoluteMs: Int,
        recordedAt: Date,
        revision: Int,
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.bookRatingKey = bookRatingKey
        self.kind = kind
        self.absoluteMs = absoluteMs
        self.recordedAt = recordedAt
        self.revision = revision
        self.attempts = attempts
        self.lastError = lastError
    }
}

/// Outcome of reconciling one book's position against the server on reconnect.
public enum Reconciliation: Sendable, Equatable {
    case adoptRemote(absoluteMs: Int)
    case pushLocal(absoluteMs: Int)
    case noChange
    /// Both sides moved since the last successful sync by more than the
    /// tolerance. Never resolved silently — losing an hour of someone's place
    /// is the one failure an audiobook app is not forgiven for.
    case conflict(local: Int, remote: Int)

    /// Divergence below this is treated as the same position. Two devices
    /// disagreeing by a few seconds is normal drift, not a conflict.
    public static let tolerance: Int = 60_000

    public static func resolve(
        localMs: Int?,
        localChangedAt: Date?,
        remoteMs: Int?,
        remoteChangedAt: Date?,
        lastSyncedAt: Date?
    ) -> Reconciliation {

        // Local counts as changed if it moved after the last successful push.
        // With no push on record, any local position at all is unsent.
        let localDirty: Bool
        if let localChangedAt {
            localDirty = lastSyncedAt.map { localChangedAt > $0 } ?? true
        } else {
            localDirty = false
        }

        // The remote is judged against the last sync when there is one, and
        // otherwise against our own last local change.
        //
        // That fallback is the whole point. A remote view older than the change
        // we already made carries no information we do not have, so treating it
        // as a competing edit invents a conflict out of nothing — which is
        // exactly what happened to a freshly installed client that had listened
        // once offline while the server still held a position from months ago.
        let remoteReference = lastSyncedAt ?? localChangedAt
        let remoteDirty: Bool
        if let remoteChangedAt {
            remoteDirty = remoteReference.map { remoteChangedAt > $0 } ?? true
        } else {
            remoteDirty = false
        }

        switch (localDirty, remoteDirty) {
        case (false, false):
            return .noChange

        case (false, true):
            guard let remoteMs else { return .noChange }
            return .adoptRemote(absoluteMs: remoteMs)

        case (true, false):
            guard let localMs else { return .noChange }
            return .pushLocal(absoluteMs: localMs)

        case (true, true):
            guard let localMs else {
                return remoteMs.map { Reconciliation.adoptRemote(absoluteMs: $0) } ?? .noChange
            }
            guard let remoteMs else { return .pushLocal(absoluteMs: localMs) }

            // Both moved since the last common point. Small disagreement is
            // ordinary drift between two devices; take whichever is further and
            // say nothing.
            if abs(localMs - remoteMs) <= tolerance {
                return .pushLocal(absoluteMs: max(localMs, remoteMs))
            }
            return .conflict(local: localMs, remote: remoteMs)
        }
    }
}
