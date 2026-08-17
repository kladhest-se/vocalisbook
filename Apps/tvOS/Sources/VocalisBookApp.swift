import SwiftUI
import UIKit
import PlexKit
import Audiobooks
import CloudKit
import Platform
import PlatformShared

@main
struct VocalisBookApp: App {
    // The only route to `didReceiveRemoteNotification`.
    //
    // A SwiftUI `App` has no equivalent, so without this a silent push has
    // nowhere to be delivered — entitlement and registration notwithstanding.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate

    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                // Applied once, at the root.
                .themed(app.themes.current)
                .task { await app.start() }
                // The television is never suspended the way a phone is, but it
                // is woken from sleep — and a book listened to on the phone
                // meanwhile should be there when the screen comes back.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { app.catchUp() }
                }
        }
    }
}

/// Root state.
///
/// Sign-in, server choice and library choice are separate phases because each
/// can fail on its own: a valid token with an unreachable server is a different
/// problem from a bad token, and collapsing them produces the "just sign in
/// again" advice that never helps.
@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case launching
        case signedOut
        case choosingServer
        case choosingLibrary
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    private(set) var servers: [PlexResource] = []
    private(set) var sections: [PlexLibrarySection] = []
    private(set) var account: PlexAccount?

    /// True when the server is unreachable or the token was rejected but the
    /// app remains usable. Downloads keep playing and the outbox keeps filling
    /// — this is a banner, not a sign-out.
    private(set) var isDegraded = false

    let keychain = KeychainStore()
    private(set) var identity: PlexClientIdentity!
    private(set) var database: AudiobookDatabase!
    private(set) var library: LibraryStore!
    private(set) var sync: SyncStore!
    private(set) var sessions: SessionStore!
    private(set) var bookmarks: BookmarkStore!
    private(set) var server: PlexServerClient?
    private(set) var sectionID: String?

    let player = AudiobookPlayer()
    let themes = ThemeStore()
    let nowPlayingReporter = NowPlayingReporter()
    private var nowPlaying: NowPlayingController?
    private var transport: PlexTransport!

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    func start() async {
        identity = DeviceIdentity.current(store: keychain, version: appVersion)
        transport = PlexTransport(client: URLSessionHTTPClient.foreground(), identity: identity)

        do {
            // A cache, not a store. tvOS may purge Caches between launches, so
            // EphemeralStore deletes and rebuilds on any failure — safe here
            // precisely because nothing authoritative lives in it, and not safe
            // on the other two ports, where the same code would destroy
            // bookmarks and session history.
            database = try EphemeralStore.open()
            library = LibraryStore(database: database)
            sync = SyncStore(database: database)
            sessions = SessionStore(database: database)

            // After the stores, because the driver needs the database, and not
            // awaited here: an iCloud account check is a network call and the
            // library should not wait behind it to appear.
            Task { await startCloudSync(database: database) }
            bookmarks = BookmarkStore(database: database)

            // Without this, CloudKit's silent pushes are never delivered and the
            // sync engine only learns about other devices when it next starts.
            RemoteNotifications.register()

            // And what to do when one arrives. Registering without this is a
            // push the system delivers, waits on, and is told nothing came of.
            RemoteNotifications.onPush = { [weak self] in
                await self?.cloud?.fetchChanges()
                self?.cloudChanged()
            }
        } catch {
            phase = .failed("Could not open the local cache: \(error.localizedDescription)")
            return
        }

        Task.detached { await ArtworkCache.shared.prune() }

        wirePlayer()
        observeTermination()

        guard let token = keychain.read(.plexToken) else {
            phase = .signedOut
            return
        }
        await connect(token: token)
    }

    /// Says goodbye when the app is being torn down deliberately.
    ///
    /// Weaker than the Mac's, and worth being plain about: this fires when the
    /// app is terminated while running or swiped away, and *not* when the system
    /// kills it after suspension — which is how most iPhone apps actually end.
    /// A session left paused by that route is one Plex has to time out on its
    /// own, and no code here can prevent it.
    ///
    /// Still worth having: the swipe-away case is the one a person performs
    /// deliberately, and it is the one they then go and look at the dashboard
    /// about.
    ///
    /// The closure reads `self` rather than the notification, so nothing
    /// non-Sendable crosses into the actor.
    private func observeTermination() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Typed, and not the closure's last expression.
                //
                // `assumeIsolated` returns whatever its body evaluates to, so a
                // bare `Task { … }` there is the return value — and with both a
                // throwing and a non-throwing `Task.init` in scope, nothing says
                // which. Naming the failure type picks one, and discarding it
                // keeps the closure returning Void.
                let ending: Task<Void, Never> = Task { await self.endSession() }
                _ = ending
            }
        }
    }

    private func wirePlayer() {
        nowPlaying = NowPlayingController(player: player)
        player.onPositionChanged = { [weak self] bookRatingKey, absoluteMs in
            guard let self else { return }
            self.sessionEnded = false
            self.savePosition {
                try self.sync.recordPosition(bookRatingKey: bookRatingKey, absoluteMs: absoluteMs)
            }
            // PlatformCapabilities.flushPositionEagerly is true here: the local
            // copy may not survive to the next launch, so the position is pushed
            // rather than left to a timer.
            if PlatformCapabilities.flushPositionEagerly {
                Task { _ = try? await self.progressSync?.drain(limit: 4) }
            }
        }
        player.onFinished = { [weak self] bookRatingKey in
            guard let self else { return }
            self.sessionEnded = true
            try? self.sessions.end(atMs: self.player.absoluteMs)
            self.save(while: "mark this book finished") {
                try self.sync.markFinished(bookRatingKey: bookRatingKey)
            }
            self.flushProgress()
            self.historyRevision += 1
            self.libraryRevision += 1
        }
        // Push on pause. Plex is the only thing carrying position between
        // devices, so a position that never leaves this one is a position the
        // next device starts from zero on.
        player.onPaused = { [weak self] in
            guard let self else { return }
            try? self.sessions.end(atMs: self.player.absoluteMs)
            self.flushProgress()
            self.historyRevision += 1
            // Immediately, not on the next heartbeat: ten seconds of the
            // dashboard showing playback that has stopped is ten seconds of it
            // being wrong.
            if let server {
                nowPlayingReporter.reportNow(
                    client: server, segment: { self.currentTimelineSegment }, state: .paused
                )
            }
        }

        player.onStopped = { [weak self] in
            guard let self else { return }

            // The session closes and the heartbeat stops, which is the whole
            // difference from a pause: a paused session sits on the Plex
            // dashboard indefinitely, and three of them at once is what somebody
            // sees who has used three devices today.
            //
            // The session is over, even though the book is still loaded.
            //
            // `stop` keeps the book so play can resume where it left off, which
            // means `bookRatingKey` is no longer the answer to "is anything
            // going on" — this flag is. Without it the heartbeat treats a
            // stopped book as a paused one and leaves the session on the
            // dashboard, which is the thing stopping is for.
            self.sessionEnded = true

            // Reported before the reporter is stopped. Stopping it first leaves
            // the server holding the last thing it was told, which was "paused".
            try? self.sessions.end(atMs: self.player.absoluteMs)
            self.flushProgress()
            self.historyRevision += 1

            // `stop` cancels the heartbeat *and* reports `.stopped` — reporting
            // it separately first would send the same thing twice.
            nowPlayingReporter.stop(client: server, segment: { self.currentTimelineSegment })
        }

        // And a session opens when it starts. Nothing wrote to the session
        // table before this, which is why there was no history and no streak.
        player.onStarted = { [weak self] bookRatingKey, absoluteMs in
            guard let self else { return }
            // The id is returned for a caller that wants to close a specific
            // session; this one closes whatever is open.
            _ = try? self.sessions.begin(
                bookRatingKey: bookRatingKey,
                atMs: absoluteMs,
                rate: self.player.rate
            )
            self.startReportingNowPlaying()
        }
        player.skipIntervalSeconds =
            UserDefaults.standard.object(forKey: "skipInterval") as? Int ?? 30
    }

    // MARK: - Connecting

    func connect(token: String) async {
        phase = .launching
        do {
            let directory = PlexResourceDirectory(transport: transport)
            servers = try await directory.servers(token: token)

            guard !servers.isEmpty else {
                phase = .failed("No Plex servers are visible to this account.")
                return
            }

            if let remembered = keychain.read(.serverIdentifier),
               let match = servers.first(where: { $0.clientIdentifier == remembered }) {
                try await select(server: match, token: token)
            } else if servers.count == 1 {
                try await select(server: servers[0], token: token)
            } else {
                phase = .choosingServer
            }
        } catch let error as PlexError where error.isAuthFailure {
            keychain.signOut()
            phase = .signedOut
        } catch {
            phase = .failed(error.plexExplanation)
        }
    }

    func select(server resource: PlexResource, token: String? = nil) async throws {
        let accountToken = token ?? keychain.read(.plexToken) ?? ""
        let racer = ConnectionRacer(
            client: URLSessionHTTPClient.foreground(),
            identity: identity
        )
        let connection = try await racer.resolve(resource, fallbackToken: accountToken)

        let client = PlexServerClient(connection: connection, transport: transport)
        self.server = client
        keychain.write(resource.clientIdentifier, for: .serverIdentifier)
        try? library.upsert(server: connection, name: resource.name)
        isDegraded = false

        sections = try await client.sections().filter(\.canContainAudiobooks)
        guard !sections.isEmpty else {
            phase = .failed("No music-type libraries on this server. Audiobooks live in a music library.")
            return
        }

        if let remembered = keychain.read(.sectionKey),
           let match = sections.first(where: { $0.key == remembered }) {
            select(section: match, serverIdentifier: resource.clientIdentifier)
        } else if sections.count == 1 {
            select(section: sections[0], serverIdentifier: resource.clientIdentifier)
        } else {
            phase = .choosingLibrary
        }
    }

    func select(section: PlexLibrarySection, serverIdentifier: String) {
        keychain.write(section.key, for: .sectionKey)
        sectionID = "\(serverIdentifier):\(section.key)"
        try? library.upsert(section: section, serverID: serverIdentifier)
        phase = .ready
        // The list is checked against Plex the moment there is a library to
        // check it against.
        //
        // Not at the end of `start`, which returns before a section has been
        // picked, and not on the scene becoming active, which happens moments
        // after launch and usually before any of this.
        refreshActiveBooks()
    }

    func signIn(token: String) async {
        keychain.write(token, for: .plexToken)
        await connect(token: token)
    }

    func signOut() {
        nowPlayingReporter.stop(client: server, segment: { self.currentTimelineSegment })
        keychain.signOut()
        server = nil
        account = nil
        sectionID = nil
        servers = []
        sections = []
        phase = .signedOut
    }

    /// Marks the session degraded rather than signing out.
    func handle(_ error: any Error) {
        if let plexError = error as? PlexError, plexError.isAuthFailure || plexError.isTransient {
            isDegraded = true
        }
    }

    func clearDegraded() { isDegraded = false }

    // MARK: - Saving

    /// Something that should have been written and was not.
    ///
    /// The app layer was 123 `try?` against about forty places that showed a
    /// user anything, and three separate faults this year were invisible for
    /// exactly that reason: the operation failed, nothing said so, and the
    /// screen looked merely empty. A read that fails leaves a blank list, which
    /// is recoverable by looking again. A *write* that fails loses something.
    private(set) var storageFailure: String?

    /// Consecutive failures of the high-frequency position write.
    ///
    /// `recordPosition` runs every few seconds. Shouting on the first failure
    /// would make a momentary database lock look like a catastrophe, and
    /// shouting on none of them is how a broken database goes unnoticed for a
    /// week. Three in a row is no longer a coincidence.
    private var positionWriteFailures = 0

    private static let positionFailureThreshold = 3

    /// Runs a write, and says so when it does not work.
    ///
    /// `while:` completes the sentence "couldn't ...", so it reads as something
    /// a person did rather than a method that returned an error.
    ///
    /// **What is deliberately not routed through here.** Reads: a failed query
    /// leaves an empty list, and looking again fixes it — a banner for every one
    /// would bury the writes. And `sessions.begin`/`end`, which run on every
    /// play and pause: they record history rather than anything asked for, and a
    /// database broken enough to lose them is already saying so through
    /// `savePosition`, which counts consecutive failures instead of shouting at
    /// the first.
    ///
    /// The rule is not "every `try?` is a bug". It is that a write somebody
    /// performed, whose failure loses something they can see, has to say so.
    /// `localizedDescription`, not `plexExplanation`, and deliberately.
    ///
    /// These are database errors. The two `failureReason`s worth showing are
    /// both about the network — the sandbox, and local network permission — and
    /// GRDB supplies none, so the explanation would be the description with
    /// extra ceremony. The sentence here already carries its own context in
    /// `action`.
    func save(while action: String, _ write: () throws -> Void) {
        do {
            try write()
            storageFailure = nil
        } catch {
            storageFailure = "Couldn't \(action). \(error.localizedDescription)"
        }
    }

    /// The same, for the position write, which is too frequent to report on
    /// sight and too important to drop.
    func savePosition(_ write: () throws -> Void) {
        do {
            try write()
            positionWriteFailures = 0
            if storageFailure != nil { storageFailure = nil }
        } catch {
            positionWriteFailures += 1
            guard positionWriteFailures >= Self.positionFailureThreshold else { return }
            storageFailure = "Your place isn't being saved. \(error.localizedDescription)"
        }
    }

    func clearStorageFailure() { storageFailure = nil }

    /// iCloud, for the data Plex cannot hold.
    ///
    /// Nil when there is no account, which is a normal state rather than a
    /// failure: everything works on the device and syncs nothing.
    private(set) var cloud: CloudSyncDriver?

    /// How many screens are asking for live updates right now.
    ///
    /// Home increments this while it is on screen and decrements when it goes
    /// away. The poll runs every few seconds while somebody is looking at a list
    /// that should be moving, and backs off when nobody is — a flat interval is
    /// either too slow for the screen that matters or too chatty for an app left
    /// open all day, and this is the difference between those two.
    private var liveWatchers = 0

    func beginLiveUpdates() { liveWatchers += 1 }
    func endLiveUpdates() { liveWatchers = max(0, liveWatchers - 1) }

    /// A poll, so being up to date does not depend on a push arriving.
    ///
    /// Pushes are the fast path and stay the fast path: when one lands the
    /// engine fetches within a second. But whether a silent push is delivered —
    /// and how promptly — is Apple's decision, varies by platform, and on a
    /// television has proved not to happen at all while the app sits open. An
    /// app that only updates when relaunched is not synced, however correct the
    /// mechanism underneath.
    ///
    /// Fifteen seconds, and a fetch against a change token when nothing has
    /// altered is close to free. This is a floor under the push, not a
    /// replacement for it.
    private var cloudPoll: Task<Void, Never>?

    private func startCloudPolling() {
        cloudPoll?.cancel()
        cloudPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                if self.iCloudSyncEnabled {
                    // Told by the count, not by a callback.
                    //
                    // Arrivals are supposed to reach the screen through
                    // `setOnApplied`, and on the television they were not:
                    // records landed in the database and the list only caught up
                    // when the app was left and reopened, which re-reads it on
                    // appear. Whether that callback fires is one more thing that
                    // can be wrong; comparing the count either side of a fetch
                    // is something this loop can see for itself.
                    let before = (await self.cloud?.status.fetched) ?? 0
                    await self.cloud?.fetchChanges()
                    await self.refreshCloudStatus()

                    let after = (await self.cloud?.status.fetched) ?? 0
                    if after != before { self.cloudChanged() }
                }

                // Three seconds while a list that should be moving is on screen,
                // half a minute otherwise. A flat interval is either too slow for
                // the screen that matters or too chatty for an app left open all
                // day.
                let seconds = self.liveWatchers > 0 ? 3 : 30
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// The engine's own state, kept so a launch is not a full fetch.
    ///
    /// In `UserDefaults` rather than the database: it belongs to CloudKit, not
    /// to the library, and putting it in the schema would mean a migration every
    /// time Apple changes its shape.
    // `nonisolated`, because the closure that reads it is `@Sendable`.
    //
    // A `static let` on a `@MainActor` type inherits that isolation, and the
    // engine calls back from wherever it likes. A `String` constant is Sendable
    // on its own, so nothing is given up by saying so.
    private nonisolated static let cloudStateKey = "cloud.state"

    /// Set while the sync layer is starting, cleared once it has.
    ///
    /// Present at launch means the last attempt did not finish — which for a
    /// crash inside sync is the only evidence there is, since a process that
    /// dies leaves nothing else behind.
    private nonisolated static let cloudStartupKey = "cloud.startup.inFlight"

    /// Whether sync was skipped this launch because the last one did not finish.
    ///
    /// Shown rather than silent: an app that quietly stops syncing is the
    /// complaint this whole area started with.
    private(set) var cloudHeldBackAfterCrash = false

    /// Tries again on the next launch.
    func retryCloudAfterCrash() {
        UserDefaults.standard.removeObject(forKey: Self.cloudStartupKey)
        cloudHeldBackAfterCrash = false
    }

    /// Whether this device syncs through iCloud at all.
    ///
    /// On by default, and off is a real choice rather than a fault: everything
    /// works without it, positions still travel through Plex, and somebody who
    /// would rather their listening history stayed on the device should not have
    /// to sign out of iCloud to get that.
    ///
    /// Turning it off stops pushing and drops the engine. What has already been
    /// sent stays in the container — this is a switch, not an erase, and saying
    /// otherwise would be a lie somebody discovers later.
    var iCloudSyncEnabled: Bool = UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true {
        didSet {
            guard iCloudSyncEnabled != oldValue else { return }
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: "cloudSyncEnabled")

            if iCloudSyncEnabled {
                // Turning it on is a resync, not a resume.
                //
                // This device's copy of the syncable state goes, and the engine
                // starts with no change token so the container sends everything
                // rather than what altered since a conversation it no longer
                // remembers. Off and on again is therefore a deliberate "make
                // this device agree with the others", which is the thing you
                // want when two of them disagree and you cannot see why.
                //
                // The library stays: it is Plex's, and rebuilding it is a full
                // re-fetch for no reason. Downloads stay for the same reason.
                Task { await resyncFromCloud() }
            } else {
                cloud = nil
                cloudStatus = nil
                cloudPoll?.cancel()
                cloudPoll = nil
            }
        }
    }

    private func startCloudSync(database: AudiobookDatabase) async {
        guard iCloudSyncEnabled else { return }

        // A crash-loop breaker, and the reason for it.
        //
        // Everything the sync layer applies came from somewhere else. If one
        // record can make this process die — a trap rather than a thrown error —
        // then every device holding that record dies at launch, on every launch,
        // and the setting that would turn sync off is behind a screen the app
        // never reaches. The data is shared, so the failure is shared, and there
        // is no way in.
        //
        // So: a flag is written before the sync layer starts and cleared once it
        // has. Finding it still set at launch means the last attempt did not
        // finish, and this one skips sync entirely rather than repeating it.
        //
        // The app is fully usable without sync. This is the difference between a
        // bad record costing somebody their listening state and costing them
        // their app.
        if UserDefaults.standard.bool(forKey: Self.cloudStartupKey) {
            UserDefaults.standard.removeObject(forKey: Self.cloudStartupKey)
            cloudHeldBackAfterCrash = true
            return
        }
        UserDefaults.standard.set(true, forKey: Self.cloudStartupKey)

        let driver = CloudSyncDriver(
            store: CloudSyncStore(database: database),
            containerIdentifier: "iCloud.se.kladhest.vocalisbook"
        )

        guard await driver.isAvailable() else {
            // Not signed in, or restricted. Asked rather than assumed, and
            // silent because the app is fully usable without it.
            return
        }

        // JSON, not `NSKeyedArchiver`.
        //
        // `CKSyncEngine.State.Serialization` is a Swift value type conforming to
        // `Codable`. The keyed archiver wants an `NSObject` that conforms to
        // `NSCoding`, which this is neither — it is the reflex for "persist an
        // Apple type" and the wrong one here.
        await driver.setOnStateChanged { state in
            guard let state, let data = try? JSONEncoder().encode(state) else {
                UserDefaults.standard.removeObject(forKey: Self.cloudStateKey)
                return
            }
            UserDefaults.standard.set(data, forKey: Self.cloudStateKey)
        }

        let restored: CKSyncEngine.State.Serialization? = {
            guard let data = UserDefaults.standard.data(forKey: Self.cloudStateKey) else {
                return nil
            }
            return try? JSONDecoder().decode(
                CKSyncEngine.State.Serialization.self, from: data
            )
        }()

        // Reload when something arrives, or a bookmark made on another device
        // sits in the database until a screen happens to reload for its own
        // reasons.
        await driver.setOnApplied { [weak self] in
            Task { @MainActor in
                self?.cloudChanged()
            }
        }

        await driver.start(stateSerialization: restored)

        // Started without dying, so the next launch may try again.
        UserDefaults.standard.removeObject(forKey: Self.cloudStartupKey)
        cloud = driver
        startCloudPolling()
    }

    /// Sends whatever is waiting, after a local change worth syncing.
    ///
    /// Fire and forget: a bookmark is saved locally first, and whether iCloud
    /// hears about it this second or next is not something to make anybody wait
    /// for.
    func syncToCloud() {
        Task { await cloud?.pushPending() }
    }



    /// Bookmarks the current position.
    ///
    /// Unlabelled, like the phone's: naming it is a second step and the moment
    /// worth marking has usually passed by the time a keyboard appears. On a
    /// television that argument is stronger — the keyboard is a grid of letters
    /// navigated with a thumb pad.
    @discardableResult
    func addBookmark() -> BookmarkRecord? {
        guard let key = player.bookRatingKey else { return nil }
        var record: BookmarkRecord?
        save(while: "save that bookmark") {
            record = try bookmarks.add(bookRatingKey: key, absoluteMs: player.absoluteMs)
        }
        bookmarkRevision += 1
        // Pushed from here rather than from every revision bump: a bump is a
        // signal to screens, and several of them have nothing to do with iCloud.
        // This is the write that made a syncable row.
        syncToCloud()
        return record
    }

    func removeBookmark(id: String) {
        save(while: "remove that bookmark") {
            try sync.deleteBookmark(id: id)
        }
        bookmarkRevision += 1
        // A deletion has to travel too: deleting locally and going quiet leaves
        // the bookmark alive on every other device, which pushes it back.
        syncToCloud()
    }

    /// Bumped when a bookmark is added or removed, so a list watching this
    /// reloads without being told by whoever changed it.
    private(set) var bookmarkRevision = 0

    /// Fetched once, from plex.tv — a server knows a token is authorised, not
    /// whose it is. Failure is silent: not knowing a name is not worth an alert
    /// on a screen someone opened to find the sign-out button.
    func loadAccount() async {
        guard account == nil, let token = keychain.read(.plexToken) else { return }
        account = try? await PlexResourceDirectory(transport: transport).account(token: token)
    }

    /// How the server was reached, which is the first thing worth knowing when
    /// playback is slow.
    /// Whether this device is talking to the server through Plex's relay.
    ///
    /// The racer tries every local address first and only falls through when all
    /// of them fail, so this is not a preference — it is a report that the LAN
    /// was unreachable. On a phone that usually means Local Network permission,
    /// which is asked once and cannot be asked again from inside the app.
    var isOnRelay: Bool {
        server?.connection.isRelay ?? false
    }

    var connectionDescription: String? {
        guard let connection = server?.connection else { return nil }
        if connection.isLocal { return "On this network" }
        return connection.isRelay ? "Relay (slow)" : "Direct"
    }

    var libraryName: String? {
        guard let key = keychain.read(.sectionKey) else { return nil }
        return sections.first { $0.key == key }?.title
    }

    var serverName: String? {
        guard let identifier = keychain.read(.serverIdentifier) else { return nil }
        return servers.first { $0.clientIdentifier == identifier }?.name
    }

    func setSkipInterval(_ seconds: Int) {
        player.skipIntervalSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "skipInterval")
    }

    /// Drains the outbox, quietly.
    ///
    /// Failure is expected and uninteresting — the entries stay queued with
    /// their backoff and the next attempt picks them up. What matters is that
    /// this is *attempted* at every natural stopping point rather than only when
    /// somebody pulls to refresh.
    /// What the server needs to place this client in its dashboard.
    ///
    /// Plex thinks in tracks, so the book-absolute position has to be turned
    /// back into a track and an offset — the same translation `BookTimeline`
    /// does for playback, used here for presence.
    var currentTimelineSegment: (trackRatingKey: String, trackKey: String, offsetMs: Int, durationMs: Int)? {
        // `locate` returns an index into the segments, not the segment itself.
        guard let timeline = player.timeline,
              let position = timeline.locate(absoluteMs: player.absoluteMs),
              timeline.segments.indices.contains(position.segmentIndex)
        else { return nil }

        let segment = timeline.segments[position.segmentIndex]
        return (
            segment.trackRatingKey,
            segment.trackKey,
            position.offsetInSegmentMs,
            segment.durationMs
        )
    }

    /// Heartbeats, so the client appears in the Plex dashboard while playing.
    ///
    /// Progress reporting alone was never enough: the dashboard is built from
    /// these, not from stored positions, so a client that only reported on pause
    /// had the right position and was invisible.
    /// Whether the current book has played to its end.
    ///
    /// The player does not go idle when a book finishes: the queue empties, the
    /// rate drops to zero, and to everything downstream that looks exactly like
    /// a pause at the last second. Plex would then show a session parked at 100%
    /// of a book nobody is listening to until it timed out — the same stale row
    /// a quit client used to leave.
    ///
    /// Cleared the moment the position moves again.
    private var sessionEnded = false

    func startReportingNowPlaying() {
        guard let server else { return }
        nowPlayingReporter.start(
            client: server,
            segment: { [weak self] in self?.currentTimelineSegment },
            state: { [weak self] in
                guard let self else { return .stopped }
                // A finished book is not a paused one. Left as paused, the
                // dashboard shows a session sitting at 100% of a book nobody is
                // listening to, for as long as Plex keeps it — the same stale
                // row a quit client used to leave.
                if self.sessionEnded || self.player.bookRatingKey == nil { return .stopped }
                return self.player.state == .playing ? .playing : .paused
            }
        )
    }

    /// Tells the server this client has gone.
    ///
    /// Plex has no other way to find out. Without a final `stopped` its
    /// dashboard shows the session paused indefinitely — which is exactly what a
    /// screenshot of a quit client showed, still listed as playing and paused
    /// forty-seven minutes in.
    ///
    /// Safe to call when nothing is playing: the reporter needs a current
    /// segment and does nothing without one.
    func endSession() async {
        nowPlayingReporter.stop(client: server, segment: { self.currentTimelineSegment })
        // A moment for the request to leave. `stop` starts it and returns, and
        // on the way out of the process there is nothing else to wait on it.
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// Sends whatever has been waiting, to both places it goes.
    ///
    /// Called on coming back online and on returning to the foreground. Offline
    /// listening piles up in the outbox and in `cloud_dirty`, and neither moves
    /// until something asks: this is that something.
    /// Brings the Continue listening list up to date with Plex.
    ///
    /// Runs at launch and whenever this device catches up after being away. The
    /// list itself is the client's — from this device and, when iCloud is on,
    /// from the others — and this asks Plex about each book on it: finished
    /// there means finished here, and a position further along there is adopted.
    ///
    /// The same sweep either way. With iCloud on the list arrives from the
    /// container first and is checked; with it off the list is whatever this
    /// device knows and is checked just the same. Plex is asked about the books
    /// on the list, never for the list itself.
    func refreshActiveBooks() {
        guard let library, let progressSync else { return }

        Task {
            // Anything listened to offline goes first, so the server is answering
            // about a position it has actually been told about. Checking before
            // pushing would adopt the server's older place over this device's
            // newer one.
            _ = try? await progressSync.drain()

            let active = ((try? library.continueListening(limit: 24)) ?? []).map(\.ratingKey)
            guard !active.isEmpty else { return }

            let changed = await progressSync.refreshActive(bookRatingKeys: active)
            if changed > 0 { cloudChanged() }
        }
    }


    func catchUp() {
        flushProgress()
        refreshActiveBooks()
        Task {
            // Pull as well as push. A push may have been missed while the app was
            // away, and asking costs one round trip against a change token.
            await cloud?.fetchChanges()
            await refreshCloudStatus()
        }
    }


    /// Sends what has been listened to, to both places it goes.
    ///
    /// Plex through the outbox, iCloud through the sync engine. This is called
    /// on pause and when a book finishes — the moments a position is worth
    /// something to another device — and not on every position change, which
    /// arrives about once a second and would be a request per second.
    ///
    /// iCloud was missing from here, which is why a device could play a whole
    /// book and report `sent 0`: the rows were marked for iCloud and nothing
    /// ever told the engine they existed. Bookmarks pushed, because their own
    /// call site did it; positions had no such call site.
    func flushProgress() {
        guard let progressSync else { return }
        Task { _ = try? await progressSync.drain() }
        syncToCloud()
    }

    // MARK: - Now playing metadata
    //
    // Held here rather than in the player: the player deals in timelines and
    // milliseconds and has no business knowing what a cover URL is.

    /// Bumped whenever something happens that changes what "continue listening"
    /// should contain. The store is a database, not an observable object, so a
    /// view reading from it has no way to know a row appeared.
    /// Which tab is showing. Held here so starting playback can switch to the
    /// player without threading a binding through every screen.
    var selectedTab: MainTab = .home

    private(set) var libraryRevision = 0

    /// Tells every screen the library has changed.
    ///
    /// `libraryRevision` is `private(set)` on purpose: a revision is a signal
    /// this type sends, not a counter for a view to poke. The mark-finished and
    /// reset actions on the book screen needed to send it and wrote to it
    /// directly, which does not compile — correctly.
    ///
    /// A named method also says what happened. `libraryRevision += 1` at a call
    /// site says how the signal is implemented and leaves the reader to infer
    /// why.
    func libraryChanged() { libraryRevision += 1 }

    /// What the app is busy doing, in a sentence somebody can read.
    ///
    /// Nil when nothing is happening, which is almost always. It exists for the
    /// one job long enough to look like a hang: fetching series tags is a request
    /// per series, and on a large library that is a minute of a blank screen with
    /// nothing to say whether it is working or broken.
    ///
    /// A sentence rather than a percentage. "Fetching series… 12 of 40" says both
    /// what is happening and that it is moving; a bare bar says only the second.
    private(set) var activity: String?

    func setActivity(_ text: String?) { activity = text }


    /// Throws away everything this device has stored and starts again.
    ///
    /// The sign-in is untouched — the token lives in the keychain and the server
    /// row is kept — so the next refresh fills the library straight back in.
    /// Throws away this device's synced state and refills it from iCloud.
    ///
    /// The order matters. Local rows first, so nothing here outranks what
    /// arrives; then the engine from scratch, so the server sends the whole zone.
    ///
    /// If the container is empty — nothing has ever synced — this leaves the
    /// device with no positions and no bookmarks until Plex is asked again, which
    /// the next refresh does. That is the honest cost of a deliberate resync and
    /// the reason it is behind a switch rather than a button somebody presses by
    /// accident.
    private func resyncFromCloud() async {
        guard let database else { return }

        save(while: "prepare this device for a resync") {
            try database.purgeSyncedUserData()
        }

        if cloud == nil {
            await startCloudSync(database: database)
        } else {
            await cloud?.restartFromScratch()
        }

        cloudChanged()
        await refreshCloudStatus()
    }

    /// The driver's own account of what it has done, for the Settings screen.
    private(set) var cloudStatus: CloudSyncDriver.Status?

    func refreshCloudStatus() async {
        cloudStatus = await cloud?.status
    }

    /// Clears the listening history: this device's, and iCloud's when it syncs.
    ///
    /// One action rather than two, because two was a distinction nobody wanted
    /// to make: if a device syncs, the cloud copy *is* its state, and clearing
    /// one without the other only means waiting a few seconds for it to come
    /// back.
    ///
    /// **The library is not touched.** It is Plex's, it costs a full re-fetch to
    /// rebuild, and nothing about a listening record lives in those tables. An
    /// earlier version deleted the section row and took every book, track,
    /// chapter, genre and collection with it by cascade — clearing a history
    /// emptied Browse and Authors as well.
    ///
    /// **Nor is Plex.** Opening a book still reconciles that book against the
    /// server, so a position Plex holds will come back for that one book when
    /// somebody plays it. The list is the client's; the file position is Plex's.
    /// Throws away everything this device has cached and builds it again.
    ///
    /// The library comes back from Plex and the listening state from iCloud, so
    /// nothing is lost that lives anywhere else — this is for when something
    /// local has gone wrong badly enough that starting over is the shortest way
    /// out.
    ///
    /// Order matters, and each step depends on the one before:
    ///
    /// 1. Stop the player, which is holding a timeline for a book that is about
    ///    to stop existing.
    /// 2. Purge the database. No downloads to remove first: a television
    ///    streams, and has no store or coordinator at all.
    /// 3. Restart the sync engine from no token, so iCloud sends everything
    ///    again rather than only what has changed since a state this device no
    ///    longer has anything to apply against.
    /// 4. Refresh from Plex.
    ///
    /// The cloud container is **not** touched. That is the whole difference from
    /// clearing your history: this throws away the copy, that throws away the
    /// original.
    func clearAllLocalData() {
        player.stop()

        Task {
            // No download step here. A television streams and has neither a
            // coordinator nor a store, so there is nothing on disk to remove.

            setActivity("Clearing local data…")
            try? database.purgeAllCachedData()

            // Everything on screen is now describing rows that are gone.
            libraryChanged()
            cloudChanged()

            if iCloudSyncEnabled {
                setActivity("Fetching from iCloud…")
                await cloud?.restartFromScratch()
            }

            setActivity("Fetching from Plex…")
            _ = try? await librarySync?.refreshBooks()

            setActivity(nil)
            libraryChanged()
        }
    }

    func clearListeningHistory() {
        // Stopped, not paused. The player holds a timeline for a book whose rows
        // are about to disappear, and a pause keeps it — letting it report
        // positions for something the database no longer knows about.
        //
        // This said "there is no `stop`" until there was one.
        player.stop()

        Task {
            // iCloud first, and awaited: clearing the database while the
            // container still holds the same records is a purge that undoes
            // itself within seconds.
            if iCloudSyncEnabled {
                await cloud?.purgeCloudData()
            }

            // The listening data only. The library stays.
            //
            // This used to call `purgeEverything`, which deletes the section row
            // — and every book, track, chapter, genre and collection cascades
            // from it. Clearing your history emptied Browse, Authors and Genres
            // as well, and cost a full re-fetch of the whole library to get them
            // back. Nothing about a listening record is stored in those tables.
            save(while: "clear this device's history") {
                try database.purgeSyncedUserData()
            }

            // The engine's own state goes too: its change tokens describe a zone
            // that no longer exists.
            UserDefaults.standard.removeObject(forKey: Self.cloudStateKey)

            cloudChanged()
            await refreshCloudStatus()
        }
    }


    /// Something arrived from another device.
    ///
    /// Bookmarks, history and per-book speed can all change at once when a batch
    /// lands, so this bumps everything rather than making the driver say which —
    /// it costs a reload of screens that are cheap to reload.
    func cloudChanged() {
        bookmarkRevision += 1
        historyRevision += 1
        libraryRevision += 1
    }


    /// Bumped when a listening session closes, so the history screen refreshes
    /// without polling.
    private(set) var historyRevision = 0

    private(set) var nowPlayingTitle: String?
    private(set) var nowPlayingAuthor: String?
    private(set) var nowPlayingThumb: String?

    // There is deliberately no `downloads` here.
    //
    // tvOS gives an app no durable local storage, so `DownloadCoordinator` does
    // not exist in this port's Platform at all — see
    // `PlatformCapabilities.supportsOfflineDownloads`, which
    // `tests/capabilities.sh` asserts is false. Referring to the type would not
    // compile, which is the intended outcome rather than an inconvenience: a
    // downloads feature here would silently lose a 900 MB file.

    func setNowPlaying(title: String, author: String?, thumb: String?) {
        nowPlayingTitle = title
        nowPlayingAuthor = author
        nowPlayingThumb = thumb
        refreshNowPlayingInfo()
        libraryRevision += 1
    }

    func refreshNowPlayingInfo() {
        guard let title = nowPlayingTitle else { return }
        nowPlaying?.update(
            title: title,
            author: nowPlayingAuthor,
            artworkURL: server?.artworkURL(thumb: nowPlayingThumb, width: 600, height: 600)
        )
    }

    /// Per-book speed memory. Falls back to the global default for a book that
    /// has never been played.
    func rate(for bookRatingKey: String) -> Float {
        let stored = try? sync.rate(bookRatingKey: bookRatingKey)
        return stored.flatMap { $0 }.map(Float.init) ?? defaultRate
    }

    func rememberRate(_ rate: Float) {
        guard let key = player.bookRatingKey else { return }
        save(while: "remember this speed") { try sync.setRate(Double(rate), bookRatingKey: key) }
        syncToCloud()
    }

    var defaultRate: Float {
        get { UserDefaults.standard.object(forKey: "defaultRate") as? Float ?? 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "defaultRate") }
    }

    // MARK: - Convenience for feature models

    var librarySync: LibrarySync? {
        guard let server, let sectionID,
              let sectionKey = keychain.read(.sectionKey) else { return nil }
        return LibrarySync(
            client: server,
            store: library,
            progress: sync,
            sectionID: sectionID,
            sectionKey: sectionKey
        )
    }

    var progressSync: ProgressSync? {
        guard let server else { return nil }
        return ProgressSync(client: server, store: sync, library: library)
    }
}
