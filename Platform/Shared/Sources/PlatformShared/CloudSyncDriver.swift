import CloudKit
import Foundation
import OSLog
import Audiobooks

/// Carries `CloudRecord`s to CloudKit and back.
///
/// The other half of the seam `CloudSyncStore` draws. That type decides what
/// syncs and how conflicts resolve, with no idea CloudKit exists; this one turns
/// its records into `CKRecord`s and back and knows nothing about revisions or
/// bookmarks.
///
/// In `PlatformShared` because all three ports need it and CloudKit is on all
/// three. It matters most on the Apple TV, where the database is a cache the
/// system may purge — there, this is the only thing that makes a bookmark
/// survive.
///
/// Plex is not involved and cannot be: it has no third-party user-data API, so
/// bookmarks, history and per-book speed have nowhere to live but the device and
/// iCloud.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
public actor CloudSyncDriver {

    /// One zone, not one per record type.
    ///
    /// A custom zone rather than the default: only a custom zone can be fetched
    /// by change token, which is the difference between syncing what changed and
    /// downloading everything on every launch.
    static let zoneID = CKRecordZone.ID(zoneName: "VocalisBook", ownerName: CKCurrentUserDefaultName)

    private let store: CloudSyncStore
    private let container: CKContainer
    private let database: CKDatabase

    /// Called with the engine's state whenever it changes, so the app can keep
    /// it across launches. A closure rather than a protocol: it is one function
    /// and the app is the only caller.
    private var onStateChanged: (@Sendable (CKSyncEngine.State.Serialization?) -> Void)?

    public func setOnStateChanged(
        _ handler: @escaping @Sendable (CKSyncEngine.State.Serialization?) -> Void
    ) {
        onStateChanged = handler
    }

    /// Whether this device has an iCloud account to sync with.
    ///
    /// Asked rather than assumed: not signed in is a normal state, and the app
    /// works without it with everything kept on the device.
    public func isAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }
    private let log = Logger(subsystem: "se.kladhest.vocalisbook", category: "cloud")

    /// The engine's own state, which it asks us to persist and hands back on the
    /// next launch. Without it every start is a full fetch.
    private var stateSerialization: CKSyncEngine.State.Serialization?
    private var engine: CKSyncEngine?

    /// The server's version of each record we have seen.
    ///
    /// A `CKRecord` carries a change tag, and the server rejects a save that does
    /// not have the current one: "record to insert already exists", error 14/2004.
    /// Building a fresh `CKRecord` for every push — which is what this did —
    /// therefore worked exactly once per record and failed forever after.
    ///
    /// Keyed by record name. Filled from what the server accepts and from the
    /// conflicts it reports, so the first save after a launch may still collide
    /// once and then resolve itself.
    private var knownRecords: [String: CKRecord] = [:]

    /// Bumped when something arrives, so a screen can reload.
    public private(set) var appliedRevision = 0

    /// What this driver has actually done, for somebody looking at a screen and
    /// wondering whether any of it works.
    ///
    /// Sync fails silently by design — a dropped push is retried, an absent
    /// account is a normal state — and the result is that "it is not syncing"
    /// and "it is syncing and there is nothing to send" look identical. This is
    /// the difference between them.
    public struct Status: Sendable, Equatable {
        public var isRunning = false
        public var pushed = 0
        public var fetched = 0
        public var lastError: String?
        public var lastActivity: Date?
    }

    public private(set) var status = Status()

    /// Called after records are applied, so the app can reload what changed.
    ///
    /// `appliedRevision` was written and never read: an actor's property is not
    /// observable from SwiftUI, so bookmarks arriving from another device landed
    /// in the database and no screen noticed until something else happened to
    /// reload. A callback is the only way out of an actor that does not involve
    /// polling it.
    private var onApplied: (@Sendable () -> Void)?

    public func setOnApplied(_ handler: @escaping @Sendable () -> Void) {
        onApplied = handler
    }

    public init(store: CloudSyncStore, containerIdentifier: String) {
        self.store = store
        self.container = CKContainer(identifier: containerIdentifier)
        // Private, always. These are one person's bookmarks and listening
        // history; nothing here is shared with anybody.
        self.database = container.privateCloudDatabase
    }

    /// Starts syncing, if the account can.
    ///
    /// Returns quietly when iCloud is unavailable — not signed in, restricted, or
    /// a simulator with no account. That is a normal state, not a failure: the
    /// app works without it and everything stays on the device.
    /// Starts again from nothing, fetching the whole zone.
    ///
    /// Passing no state serialization is what makes this a full fetch: the
    /// engine has no change token, so the server sends everything rather than
    /// what has altered since a conversation it does not remember.
    ///
    /// The caller clears the local rows first. This side only forgets what it
    /// knew about the server.
    public func restartFromScratch() async {
        engine = nil
        knownRecords.removeAll()
        stateSerialization = nil
        status = Status()
        onStateChanged?(nil)
        await start(stateSerialization: nil)
    }

    public func start(stateSerialization: CKSyncEngine.State.Serialization? = nil) async {
        guard engine == nil else { return }

        self.stateSerialization = stateSerialization

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: stateSerialization,
            delegate: self
        )
        configuration.automaticallySync = true

        let engine = CKSyncEngine(configuration)
        self.engine = engine

        // The zone has to exist before anything can be saved into it.
        //
        // A custom zone is not created for you — saving a record into one that
        // is not there fails, and the first sync would fail on every record for
        // a reason that reads as a permissions problem.
        //
        // Added on every start rather than once: a zone save is idempotent, the
        // engine coalesces it away when the zone is already there, and tracking
        // "have I made the zone" locally is a second piece of state that can
        // disagree with the server.
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: Self.zoneID))
        ])

        status.isRunning = true
        await pushPending()
    }

    /// Deletes everything this app has put in the container.
    ///
    /// The zone, not the records one by one: it is a single change, it cannot
    /// half-succeed, and it takes anything a future version of this app might
    /// have added without needing a list.
    ///
    /// Called when somebody removes this device's cached data. Without it the
    /// purge looks like it did nothing — the local rows go, the engine fetches
    /// the same records back a moment later, and the state that was being thrown
    /// away reappears.
    ///
    /// The zone is queued for recreation straight after, so the next position
    /// this device records has somewhere to go.
    ///
    /// **This is not device-local.** The container is shared, so the records
    /// disappear for every device on the account. Another device still holding
    /// its own copy will push it back, which is usually what somebody wants —
    /// they are clearing a device, not abandoning their history — but it is not
    /// an erase of the account and should not be described as one.
    public func purgeCloudData() async {
        guard let engine else { return }

        knownRecords.removeAll()
        engine.state.add(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: Self.zoneID))
        ])
    }

    /// Asks the server for anything new, now.
    ///
    /// The engine fetches on its own when a push arrives, and pushes are the
    /// mechanism that makes this live. This is the fallback for the moments a
    /// push may have been missed — coming back to the app, or a manual refresh —
    /// and it costs one round trip against a change token, so it is cheap enough
    /// to ask whenever somebody looks.
    public func fetchChanges() async {
        try? await engine?.fetchChanges()
    }

    /// Queues everything the store has waiting.
    ///
    /// Called after `start`, and whenever something local changes. The engine
    /// coalesces: asking twice for the same record sends it once.
    public func pushPending() async {
        guard let engine else { return }

        enqueuePending()

        // Sent now, rather than when the engine decides.
        //
        // `state.add` only queues: `automaticallySync` then picks its own moment,
        // which is the right behaviour for a background trickle of edits and the
        // wrong one for the single event somebody is waiting on. Pausing a book
        // is that event — the other device should list it within a second, not
        // whenever the scheduler next feels like it.
        //
        // Cheap because it is rare: this runs on pause and on finishing a book,
        // not on every position change.
        //
        // **Never call this from a delegate callback.** Awaiting `sendChanges`
        // inside one is a fatal error by CloudKit's own check — it cannot promise
        // to call the delegate serially if the delegate is waiting on it. Use
        // `enqueuePending()` there and let `automaticallySync` do the sending.
        try? await engine.sendChanges()
    }

    /// Queues what is dirty, without asking the engine to send.
    ///
    /// The half of `pushPending` that is safe inside a delegate callback.
    /// `state.add` is bookkeeping on the engine's own state and does not call
    /// back into it; `sendChanges` does, and awaiting that from a callback
    /// crashes the process:
    ///
    ///     BUG IN CLIENT OF CLOUDKIT: Cannot await a call into CKSyncEngine from
    ///     within a delegate callback…
    ///
    /// Which is exactly what happened, on two devices at once, the moment one
    /// started playing while the other was already streaming: enough records
    /// crossed for a batch to be rejected, the rejection handler pushed back,
    /// and both processes died inside the callback that was handling it.
    ///
    /// What is queued here still goes out — `automaticallySync` sends it — a
    /// moment later rather than immediately, which for a record the *other*
    /// device is waiting on is the correct trade for not crashing.
    public func enqueuePending() {
        guard let engine else { return }

        let pending = (try? store.pendingChanges()) ?? []
        guard !pending.isEmpty else { return }

        let ids = pending.map {
            CKRecord.ID(recordName: $0.recordName, zoneID: Self.zoneID)
        }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
    }
}

// MARK: - The engine's delegate

@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
extension CloudSyncDriver: CKSyncEngineDelegate {

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            // Persisted by the caller, because this actor has nowhere to put it
            // that survives a launch and the app already owns a defaults store.
            stateSerialization = update.stateSerialization
            onStateChanged?(update.stateSerialization)

        case .fetchedRecordZoneChanges(let changes):
            await apply(changes)

        case .sentRecordZoneChanges(let sent):
            await markPushed(sent)

        case .accountChange(let change):
            // A different iCloud account is a different set of bookmarks. The
            // local database is not wiped — it holds Plex's data too, which is
            // nobody's private business — but the sync state is, or the new
            // account inherits the old one's change tokens.
            switch change.changeType {
            case .signIn, .switchAccounts:
                stateSerialization = nil
                onStateChanged?(nil)
                // Queued, not sent: this is a delegate callback.
                enqueuePending()
            case .signOut:
                stateSerialization = nil
                onStateChanged?(nil)
            @unknown default:
                break
            }

        default:
            // `willFetchChanges`, `didFetchChanges`, progress events and whatever
            // Apple adds next. Nothing here needs them, and matching them
            // exhaustively would break on the first new case.
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = (try? store.pendingChanges()) ?? []
        guard !pending.isEmpty else { return nil }

        let byName = Dictionary(uniqueKeysWithValues: pending.map { ($0.recordName, $0) })

        // Filtered by asking the scope about each change, rather than handing it
        // the list.
        //
        // The scope narrows what this batch may include — the engine sometimes
        // asks for a subset, a single zone, or a retry of what failed — so
        // sending everything pending regardless would push records it did not
        // ask for.
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter {
            scope.contains($0)
        }

        let known = knownRecords

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: changes
        ) { recordID in
            guard let local = byName[recordID.recordName] else { return nil }

            // The server's record if we have it, so its change tag travels with
            // the save. A fresh `CKRecord` has no tag and the server refuses it
            // as an insert of something that already exists.
            let base = known[recordID.recordName]
                ?? CKRecord(recordType: local.kind.rawValue, recordID: recordID)

            return Self.apply(local, to: base)
        }
    }
}

// MARK: - Mapping

@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
extension CloudSyncDriver {

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        var incoming: [CloudRecord] = []

        for record in changes.modifications {
            // A fetched record is the server's current version, tag and all —
            // the same thing a save needs to build on. Remembering it here means
            // the first push after a fetch does not have to collide to learn it.
            knownRecords[record.record.recordID.recordName] = record.record

            if let mapped = Self.cloudRecord(from: record.record) {
                incoming.append(mapped)
            }
        }

        // A deletion arrives as an id and nothing else, so the kind has to come
        // out of the name — which is why `recordName` carries it.
        for deletion in changes.deletions {
            knownRecords[deletion.recordID.recordName] = nil

            if let mapped = Self.tombstone(forRecordName: deletion.recordID.recordName) {
                incoming.append(mapped)
            }
        }

        guard !incoming.isEmpty else { return }

        do {
            let result = try store.apply(incoming)
            appliedRevision += 1
            status.fetched += result.applied
            status.lastActivity = Date()
            log.debug("applied \(result.applied), rejected \(result.rejected)")

            if result.applied > 0 { onApplied?() }

            // Rejected records are ones this device has a newer version of. They
            // are still dirty, so queueing them is how the other device learns it
            // was behind.
            //
            // Queued rather than sent, because this runs inside `handleEvent`.
            // Awaiting `sendChanges` here is the crash: two devices playing at
            // once produced a rejected batch, this line pushed back from within
            // the callback handling it, and CloudKit's own assertion killed both
            // processes — then killed them again on every launch, because the
            // records were still there to be fetched.
            if result.rejected > 0 {
                enqueuePending()
            }
        } catch {
            log.error("could not apply: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func markPushed(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) async {
        // What the server accepted is now the version to build the next save on.
        for record in sent.savedRecords {
            knownRecords[record.recordID.recordName] = record
        }
        if !sent.savedRecords.isEmpty {
            status.pushed += sent.savedRecords.count
            status.lastActivity = Date()
            status.lastError = nil
        }
        // Reported per batch, not once ever. Keyed on `status.pushed == 0` this
        // would have gone quiet after the first success and never mentioned a
        // failure again — which is the same silence the status exists to break.
        if sent.savedRecords.isEmpty, let failure = sent.failedRecordSaves.first {
            status.lastError = failure.error.localizedDescription
        }

        // And what it rejected for being out of date carries the version we
        // should have used. Kept, and the change queued again — the next batch
        // builds on the server's record and succeeds.
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves {
            guard case .serverRecordChanged = failure.error.code else { continue }

            if let server = failure.error.serverRecord {
                knownRecords[server.recordID.recordName] = server
                retry.append(.saveRecord(server.recordID))
                continue
            }

            // "record to insert already exists" — the same error code, and no
            // record attached.
            //
            // This is the variant that stalls forever. The server holds a record
            // this device has never seen, so every save is an insert of
            // something that exists; the previous version required
            // `serverRecord`, found nil, and skipped — so nothing was learned
            // and the next attempt failed identically. `sent 0` on a device with
            // a container full of records was exactly that loop.
            //
            // It happens on every launch after the first: `knownRecords` is held
            // in memory, so a relaunch forgets every change tag while the server
            // remembers all of them.
            //
            // Asked for directly, since the error will not say.
            if let fetched = try? await database.record(for: failure.record.recordID) {
                knownRecords[fetched.recordID.recordName] = fetched
                retry.append(.saveRecord(fetched.recordID))
            }
        }
        if !retry.isEmpty {
            engine?.state.add(pendingRecordZoneChanges: retry)
        }

        let names = Set(sent.savedRecords.map(\.recordID.recordName)
                        + sent.deletedRecordIDs.map(\.recordName))
        guard !names.isEmpty else { return }

        let pending = (try? store.pendingChanges()) ?? []
        let confirmed = pending.filter { names.contains($0.recordName) }
        guard !confirmed.isEmpty else { return }

        try? store.markPushed(confirmed)
    }

    /// Writes the local fields onto a record, which may be the server's.
    ///
    /// Takes a record rather than making one, so a save can carry the change tag
    /// of the version the server currently holds.
    static func apply(_ local: CloudRecord, to record: CKRecord) -> CKRecord {
        record["revision"] = local.revision as CKRecordValue
        record["isDeleted"] = (local.isDeleted ? 1 : 0) as CKRecordValue

        for (key, value) in local.fields {
            switch value {
            case .string(let string): record[key] = string as CKRecordValue
            case .int(let int): record[key] = int as CKRecordValue
            case .double(let double): record[key] = double as CKRecordValue
            case .date(let date): record[key] = date as CKRecordValue
            }
        }
        return record
    }

    /// Fields the store reads with `doubleValue`.
    ///
    /// One entry, and it is listed rather than inferred because getting it wrong
    /// is silent: the store would read nil and fall back, and a book would play
    /// at 1× having been set to 1.5.
    static let doubleFields: Set<String> = ["rate"]

    static func cloudRecord(from record: CKRecord) -> CloudRecord? {
        guard let kind = CloudRecord.Kind(rawValue: record.recordType) else {
            // A record type this version does not know about. A newer client
            // wrote it; ignoring it is correct and dropping the whole batch is
            // not.
            return nil
        }

        var fields: [String: CloudValue] = [:]
        for key in record.allKeys() where key != "revision" && key != "isDeleted" {
            switch record[key] {
            case let value as String: fields[key] = .string(value)
            case let value as Date: fields[key] = .date(value)
            case let value as Int: fields[key] = .int(value)
            case let value as Double: fields[key] = .double(value)
            case let value as NSNumber:
                // The field decides the type, not the value.
                //
                // CloudKit hands numbers back as `NSNumber`, which bridges to
                // both `Int` and `Double`, so a numeric field may miss the cases
                // above. Guessing from the value is what a first draft did and
                // it is wrong in a way that would be hard to find: `rate` is the
                // one double this app syncs, the store reads it with
                // `doubleValue`, and a rate of exactly 1.0 guessed as an int
                // would come back nil and reset somebody's speed.
                //
                // `Self.doubleFields` is the list, taken from what the store
                // writes.
                fields[key] = Self.doubleFields.contains(key)
                    ? .double(value.doubleValue)
                    : .int(value.intValue)
            default:
                continue
            }
        }

        let id = String(record.recordID.recordName.dropFirst(kind.rawValue.count + 1))

        return CloudRecord(
            kind: kind,
            id: id,
            revision: record["revision"] as? Int ?? 0,
            isDeleted: (record["isDeleted"] as? Int ?? 0) == 1,
            fields: fields
        )
    }

    /// A deletion carries no fields, so the kind and id come out of the name.
    static func tombstone(forRecordName name: String) -> CloudRecord? {
        guard let kind = CloudRecord.Kind.allCases.first(where: {
            name.hasPrefix("\($0.rawValue)-")
        }) else { return nil }

        return CloudRecord(
            kind: kind,
            id: String(name.dropFirst(kind.rawValue.count + 1)),
            // Revision 0 would lose to anything local. `Int.max` is wrong too —
            // a tombstone should not beat a later edit. The store compares
            // revisions, and CloudKit gave us none here, so this takes the
            // deletion at face value and lets the store's own rule decide.
            revision: Int.max,
            isDeleted: true,
            fields: [:]
        )
    }
}
