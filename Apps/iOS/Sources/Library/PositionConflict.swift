import Foundation
import PlatformShared

/// Two positions for one book that disagree, and neither side can say which is
/// right.
///
/// Raised when this device and the server have both moved since the last
/// successful sync. `Reconciliation` has always returned that case and always
/// carried the same note — that a conflict must never be resolved silently,
/// because losing an hour of somebody's place is the one failure an audiobook
/// app is not forgiven for.
///
/// Nothing handled it, so the local position won by default and an evening of
/// listening on another device vanished without a word. This type exists so the
/// question reaches somebody who can answer it.
///
/// Rare by construction: it needs two devices, listening on both, and no network
/// between them for long enough that neither learned of the other.
struct PositionConflict: Identifiable, Hashable {
    let local: Int
    let remote: Int

    /// Stable for the pair, so re-raising the same conflict does not re-present
    /// a dialog somebody is already looking at.
    var id: String { "\(local)-\(remote)" }

    var localText: String { Format.duration(ms: local) }
    var remoteText: String { Format.duration(ms: remote) }

    /// Which is further into the book.
    ///
    /// Offered as a hint rather than a default. Further along is usually the one
    /// somebody wants, but not always — somebody who deliberately went back to
    /// re-listen to a chapter has the earlier position and means it.
    var furtherIsRemote: Bool { remote > local }
}
