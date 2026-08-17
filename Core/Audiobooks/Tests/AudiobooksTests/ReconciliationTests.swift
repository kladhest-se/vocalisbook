import Foundation
import Testing
@testable import Audiobooks

/// Which device's idea of "where you were" wins.
///
/// `Reconciliation.resolve` is a pure function deciding whether to adopt the
/// server's position, push this device's, or refuse to choose — and it had no
/// tests, in a file whose own comments describe a bug it was written to fix.
///
/// Its own doc says it: losing an hour of someone's place is the one failure an
/// audiobook app is not forgiven for.
@Suite("Position reconciliation")
struct ReconciliationTests {

    private let synced = Date(timeIntervalSince1970: 1_700_000_000)
    private var before: Date { synced.addingTimeInterval(-3_600) }
    private var after: Date { synced.addingTimeInterval(3_600) }

    // MARK: - Nothing to do

    @Test("Neither side moved since the last sync")
    func neitherMoved() {
        let result = Reconciliation.resolve(
            localMs: 1_000, localChangedAt: before,
            remoteMs: 1_000, remoteChangedAt: before,
            lastSyncedAt: synced
        )
        #expect(result == .noChange)
    }

    @Test("A device that has never played anything has nothing to push")
    func noLocalPositionAtAll() {
        let result = Reconciliation.resolve(
            localMs: nil, localChangedAt: nil,
            remoteMs: nil, remoteChangedAt: nil,
            lastSyncedAt: nil
        )
        #expect(result == .noChange)
    }

    /// A fresh install against a server that has been listened to: nothing
    /// local, no sync on record, so there is nothing here to weigh the remote
    /// against and the remote is all the information there is.
    ///
    /// Distinct from "both moved but nothing local" below, where this device has
    /// a change to its name even though it has no position.
    @Test("A fresh install with nothing local adopts whatever the server has")
    func freshInstallAdopts() {
        let result = Reconciliation.resolve(
            localMs: nil, localChangedAt: nil,
            remoteMs: 900_000, remoteChangedAt: after,
            lastSyncedAt: nil
        )
        #expect(result == .adoptRemote(absoluteMs: 900_000))
    }

    // MARK: - One side moved

    @Test("Only the other device moved, so its position is adopted")
    func remoteMovedAlone() {
        let result = Reconciliation.resolve(
            localMs: 1_000, localChangedAt: before,
            remoteMs: 500_000, remoteChangedAt: after,
            lastSyncedAt: synced
        )
        #expect(result == .adoptRemote(absoluteMs: 500_000))
    }

    @Test("Only this device moved, so its position is pushed")
    func localMovedAlone() {
        let result = Reconciliation.resolve(
            localMs: 500_000, localChangedAt: after,
            remoteMs: 1_000, remoteChangedAt: before,
            lastSyncedAt: synced
        )
        #expect(result == .pushLocal(absoluteMs: 500_000))
    }

    /// A position never sent is unsent, whatever the server says. With no push
    /// on record there is nothing to compare against.
    @Test("With no sync on record, any local position counts as unsent")
    func noSyncMeansLocalIsDirty() {
        let result = Reconciliation.resolve(
            localMs: 500_000, localChangedAt: after,
            remoteMs: nil, remoteChangedAt: nil,
            lastSyncedAt: nil
        )
        #expect(result == .pushLocal(absoluteMs: 500_000))
    }

    // MARK: - The bug this function carries a comment about

    /// A fresh install that listened once offline, against a server holding a
    /// position from months ago.
    ///
    /// There is no `lastSyncedAt`, so the remote is judged against the local
    /// change instead. A remote view *older* than the change already made here
    /// carries no information this device does not have — treating it as a
    /// competing edit invents a conflict out of nothing, and asks somebody to
    /// choose between their place and a stale one.
    @Test("A stale remote position is not a conflict on a fresh install")
    func staleRemoteOnFreshInstall() {
        let monthsAgo = synced.addingTimeInterval(-60 * 24 * 3_600)

        let result = Reconciliation.resolve(
            localMs: 500_000, localChangedAt: after,
            remoteMs: 12_000_000, remoteChangedAt: monthsAgo,
            lastSyncedAt: nil
        )
        #expect(result == .pushLocal(absoluteMs: 500_000))
    }

    /// And the other direction: a remote newer than the local change *is* real
    /// news, even with no sync on record — so both sides count as moved and the
    /// disagreement is reported rather than one being quietly discarded.
    ///
    /// The asymmetry with the test above is the whole design: the fallback
    /// suppresses a *stale* remote, not every remote.
    @Test("A remote newer than the local change counts as a real edit")
    func newerRemoteOnFreshInstall() {
        let result = Reconciliation.resolve(
            localMs: 500_000, localChangedAt: synced,
            remoteMs: 900_000, remoteChangedAt: after,
            lastSyncedAt: nil
        )
        #expect(result == .conflict(local: 500_000, remote: 900_000))
    }

    // MARK: - Both moved

    /// Two devices a few seconds apart are not in conflict. They are two devices
    /// with a network between them.
    @Test("Small disagreement takes the further position and says nothing")
    func driftIsNotConflict() {
        let result = Reconciliation.resolve(
            localMs: 500_000, localChangedAt: after,
            remoteMs: 530_000, remoteChangedAt: after,
            lastSyncedAt: synced
        )
        #expect(result == .pushLocal(absoluteMs: 530_000))
    }

    @Test("The tolerance boundary is inclusive")
    func exactlyTheTolerance() {
        let result = Reconciliation.resolve(
            localMs: 500_000, localChangedAt: after,
            remoteMs: 500_000 + Reconciliation.tolerance, remoteChangedAt: after,
            lastSyncedAt: synced
        )
        #expect(result == .pushLocal(absoluteMs: 500_000 + Reconciliation.tolerance))
    }

    /// Past the tolerance, refuse to choose. Silently picking one loses the
    /// other, and this is the failure the doc comment says is unforgivable.
    @Test("A real disagreement is reported rather than resolved")
    func genuineConflict() {
        let result = Reconciliation.resolve(
            localMs: 500_000, localChangedAt: after,
            remoteMs: 5_000_000, remoteChangedAt: after,
            lastSyncedAt: synced
        )
        #expect(result == .conflict(local: 500_000, remote: 5_000_000))
    }

    /// Both sides moved, but this one has no position to offer — which happens
    /// when a local database is rebuilt while the server kept listening.
    @Test("Both moved but nothing local means the remote wins")
    func bothMovedWithoutLocalPosition() {
        let result = Reconciliation.resolve(
            localMs: nil, localChangedAt: after,
            remoteMs: 900_000, remoteChangedAt: after,
            lastSyncedAt: synced
        )
        #expect(result == .adoptRemote(absoluteMs: 900_000))
    }

    @Test("Both moved but nothing remote means this device wins")
    func bothMovedWithoutRemotePosition() {
        let result = Reconciliation.resolve(
            localMs: 900_000, localChangedAt: after,
            remoteMs: nil, remoteChangedAt: after,
            lastSyncedAt: synced
        )
        #expect(result == .pushLocal(absoluteMs: 900_000))
    }

    /// The tolerance is a minute, which is the number the rest of this reasoning
    /// depends on: it has to be long enough to cover ordinary drift between two
    /// clients and short enough that a real divergence is never swallowed.
    @Test("Drift tolerance is a minute")
    func tolerance() {
        #expect(Reconciliation.tolerance == 60_000)
    }
}
