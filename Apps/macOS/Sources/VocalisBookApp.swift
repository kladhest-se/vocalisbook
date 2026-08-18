import SwiftUI
import AppKit
import PlexKit
import Audiobooks
import CloudKit
import Platform
import PlatformShared

@main
struct VocalisBookApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(id: "library") {
            RootView()
                .environment(app)
                // Applied once, at the root.
                .themed(app.themes.current)
                // Narrow enough to reach the compact player. The old floor of
                // 900 made that layout unreachable by dragging, which is the
                // only way it is meant to be reached.
                //
                // `WindowSizer.windowMinSize`, not `WindowSizer.miniSize` —
                // this was 380×480 for a long time, chosen back when
                // `compactWidth` (620) was the only threshold the compact
                // player had. Once the tier system inside it grew a genuine
                // minimum of its own — the ultra-minimal, art-filling state
                // at 140×160 — this constraint was never revisited to match,
                // and stayed the real, binding floor regardless: no fix to
                // anything inside `CompactPlayerView` could ever have
                // mattered, because the window was never being handed a size
                // small enough to reach the code paths those fixes were
                // written for. `WindowSizer.applyChrome`'s own
                // `NSWindow.minSize` was set correctly this whole time and
                // was consistently the loser against this larger, declarative
                // one.
                //
                // Ideal as well as minimum.
                //
                // A minimum on its own let the window open at that minimum, so
                // a fresh launch showed the mini player rather than the library.
                // The ideal is what `defaultSize` and a first launch use; the
                // minimum only says how small dragging may go.
                .frame(
                    minWidth: WindowSizer.windowMinSize.width,
                    idealWidth: WindowSizer.regularSize.width,
                    minHeight: WindowSizer.windowMinSize.height,
                    idealHeight: WindowSizer.regularSize.height
                )
                .task { await app.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { app.catchUp() }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            PlaybackCommands(app: app)
            AccountCommands(app: app)
            AboutCommand()
        }

        // ⌘, opens this, as it does everywhere else on the platform.
        Settings {
            SettingsView()
                .environment(app)
                .themed(app.themes.current)
                // One window, sized here.
                //
                // A `Settings` scene takes its size from its content, and the
                // content is a grouped `Form` with no height — so the window
                // grew until it ran out of screen and then clipped the last
                // section, which is how the Downloads row ended up cut in half.
                //
                // Fixed rather than resizable because there is nothing here that
                // benefits from more room; if the list outgrows this the Form
                // scrolls, which is the right answer for a settings window and
                // the wrong one for a window that keeps getting taller.
                .frame(width: 480, height: 560)
        }
        .windowResizability(.contentSize)

        // Always there.
        //
        // Not optional, because it is what keeps the app reachable once the
        // window is closed — and closing the window while a book plays is the
        // ordinary case for this app, not an edge one.
        //
        // The label falls back to a symbol when the asset does not resolve.
        // `Image("…")` for a name that is not in the catalog is not an error and
        // does not draw anything — it produces a zero-size label, and a menu bar
        // item with a zero-size label is *present and invisible*. That is the
        // worst shape a failure can have here: the item is there, it responds to
        // a click nobody can aim at, and nothing anywhere reports a problem.
        // With this, a missing asset shows a generic symbol instead, which is
        // wrong in a way that can be seen and reported.
        MenuBarExtra {
            MenuBarContent()
                .environment(app)
        } label: {
            if NSImage(named: app.menuBar.style.assetName) != nil {
                Image(app.menuBar.style.assetName)
            } else {
                Image(systemName: "headphones")
            }
        }
    }
}

/// Root state.
///
/// Deliberately the same shape as the iOS one — sign-in, server choice and
/// library choice as separate phases, because each fails on its own and a valid
/// token with an unreachable server is a different problem from a bad token.
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
    private(set) var isDegraded = false

    /// Offline mode, chosen rather than detected.
    ///
    /// Distinct from `isDegraded`, which is the app noticing the server has gone
    /// away. This is somebody saying "do not go looking" — on a plane, on a
    /// metered connection, or simply because the library should show what will
    /// actually play. Detection cannot replace it: a captive-portal Wi-Fi looks
    /// connected and answers every request with a login page.
    ///
    /// Persisted, because a mode that resets on launch is one you have to set
    /// again in the exact situation where you cannot check whether it took.
    var isOffline: Bool = UserDefaults.standard.bool(forKey: "offlineMode") {
        didSet {
            UserDefaults.standard.set(isOffline, forKey: "offlineMode")
            if isOffline {
                // Stop the heartbeat immediately rather than at the next tick.
                nowPlayingReporter.stop(client: server, segment: { self.currentTimelineSegment })
                pauseIfStreaming()
            } else {
                // Back online: the note described a state that no longer holds.
                offlineNotice = nil

                // And everything held back while there was no network goes now.
                //
                // Both destinations: the outbox has positions Plex has not seen,
                // and `cloud_dirty` rows have been piling up for iCloud. Neither
                // retries on its own — the outbox drains when something calls
                // it, and the sync engine only knows about changes it has been
                // told of.
                catchUp()
            }
            libraryRevision += 1
        }
    }

    /// Stops playback that is coming over the network, on going offline.
    ///
    /// Going offline narrowed every list to downloaded books and left whatever
    /// was already playing streaming happily — so the app was in a mode that
    /// says "nothing here needs a connection" while using one, and the first
    /// sign of it was the audio stopping in a tunnel.
    ///
    /// Paused rather than unloaded: the book stays on screen, the position is
    /// kept, and pressing play again once back online resumes it. Somebody who
    /// switched the mode by accident loses nothing.
    ///
    /// Judged per part, because a book can be half downloaded — the part playing
    /// right now is the one that matters, and its neighbours are checked too so
    /// playback does not stop a minute later at a file boundary.
    private func pauseIfStreaming() {
        guard player.state == .playing, let timeline = player.timeline else { return }
        guard !isFullyDownloaded(timeline.segments) else { return }

        player.pause()
        offlineNotice = "Paused: this book isn't downloaded, and you're offline."
    }

    /// Whether every part of a book is on this device.
    ///
    /// Takes the segments rather than a timeline, because the two callers hold
    /// different types that both have them: the player has a `BookTimeline`, the
    /// book screen has the `CachedTimeline` it was about to build one from.
    ///
    /// Per part, because a half-downloaded book plays and then stops at a file
    /// boundary — which is a worse way to find out than being told now.
    func isFullyDownloaded(_ segments: [BookTimeline.Segment]) -> Bool {
        segments.allSatisfy {
            downloads.localURL(forPartCacheKey: $0.partCacheKey) != nil
        }
    }

    /// Says why nothing happened when a book was asked to play offline.
    func reportOfflineRefusal() {
        offlineNotice = "This book isn't downloaded. Turn off offline mode to stream it."
    }

    /// Closes the gate on the player, so every path is covered.
    ///
    /// Called once, when the player is wired. The closure is the same question
    /// the buttons ask, which is the point: one answer, however playback was
    /// started.
    ///
    /// `[weak self]` because the player is owned by this type — a strong capture
    /// would be a cycle from an object to the thing that holds it.
    private func gatePlaybackWhenOffline() {
        player.canStartPlayback = { [weak self] in
            guard let self else { return true }
            guard isOffline, let timeline = player.timeline else { return true }
            guard !isFullyDownloaded(timeline.segments) else { return true }

            // The Lock Screen has nowhere to show this, but the app does, and
            // somebody who pressed play there will look at the app next.
            reportOfflineRefusal()
            return false
        }
    }

    /// The play/pause button, everywhere in the app.
    ///
    /// The refusal itself lives on the player now, as `canStartPlayback`, so
    /// this no longer checks anything — `player.play()` will decline on its own
    /// and the notice will already be on screen.
    ///
    /// Kept as a name rather than replaced by `player.togglePlayPause()` at every
    /// call site: one place for the transport to go through is worth having when
    /// the next rule about starting playback arrives, and the buttons already
    /// point here.
    ///
    /// The body is `player.togglePlayPause()` and not a call to itself. A blanket
    /// substitution once routed every `player.togglePlayPause()` in the app
    /// through this method — including the one inside it — and pressing pause
    /// crashed the app after thirty-seven thousand frames.
    func togglePlayPauseRespectingOffline() {
        player.togglePlayPause()
    }

    /// Why playback stopped, when it stopped because of the offline switch.
    ///
    /// Its own property rather than `storageFailure`, which is about writes that
    /// did not land. This is neither a failure nor a surprise — it is the mode
    /// doing what it says — so it reads as a note and clears itself when the
    /// mode does.
    private(set) var offlineNotice: String?

    func clearOfflineNotice() { offlineNotice = nil }

    /// Downloads over a metered connection.
    ///
    /// Read at launch, because the background session's configuration is fixed
    /// when the session is made. Off by default: an audiobook is hundreds of
    /// megabytes and nobody expects one to arrive over cellular unasked.
    static var allowsExpensiveDownloads: Bool {
        get { UserDefaults.standard.bool(forKey: "downloads.allowExpensiveNetwork") }
        set { UserDefaults.standard.set(newValue, forKey: "downloads.allowExpensiveNetwork") }
    }

    let keychain = KeychainStore()
    private(set) var identity: PlexClientIdentity!
    private(set) var database: AudiobookDatabase!
    private(set) var library: LibraryStore!
    private(set) var sync: SyncStore!
    private(set) var sessions: SessionStore!
    private(set) var bookmarks: BookmarkStore!
    private(set) var downloadStore: DownloadStore!
    private(set) var downloads: BackgroundDownloadCoordinator!
    private(set) var server: PlexServerClient?
    private(set) var sectionID: String?

    let player = AudiobookPlayer()
    let themes = ThemeStore()
    let nowPlayingReporter = NowPlayingReporter()
    let menuBar = MenuBarSettings()
    private var nowPlaying: NowPlayingController?
    private var transport: PlexTransport!

    /// Bumped whenever something happens that changes what "continue listening"
    /// should contain.
    ///
    /// The store is a database, not an observable object, so a view reading from
    /// it has no way to know a row appeared. Without this the sidebar only
    /// refreshed when the view was rebuilt — which is why shrinking to the mini
    /// player and back appeared to fix it.
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
    /// 2. Delete the downloaded files, while the rows naming them are still
    ///    there to say which files those are. Purging first would leave the
    ///    bytes on disk with nothing pointing at them.
    /// 3. Purge the database.
    /// 4. Restart the sync engine from no token, so iCloud sends everything
    ///    again rather than only what has changed since a state this device no
    ///    longer has anything to apply against.
    /// 5. Refresh from Plex.
    ///
    /// The cloud container is **not** touched. That is the whole difference from
    /// clearing your history: this throws away the copy, that throws away the
    /// original.
    func clearAllLocalData() {
        player.stop()

        Task {
            setActivity("Removing downloads…")
            // One call, on the type that owns both halves. Reaching past it to
            // pair the store with the coordinator meant calling
            // `evict(partCacheKey:)` — the protocol's method, which takes a
            // different kind of key and would have deleted nothing.
            try? downloads.evictAll()

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

    /// Bumped when something outside the library asks it to refresh.
    ///
    /// A menu command cannot reach a view's model, and the model belongs to the
    /// view rather than to this. A counter is the smallest thing both can see.
    var libraryRefreshRequested = 0

    /// A book the app wants shown, set from somewhere that cannot navigate.
    ///
    /// The Mac has no navigation stack for books: the detail pane is whatever
    /// `LibraryView`'s selection says, and a view inside that pane has no way to
    /// change it. Rather than thread a binding through every screen that shows a
    /// book, the request goes here and `LibraryView` watches it.
    ///
    /// Cleared once honoured, so selecting the same book twice in a row works.
    var requestedBook: String?

    /// Which books are fully downloaded, for the badge on a cover.
    ///
    /// Held here rather than passed to every grid: tiles are drawn from several
    /// screens, and a parameter would have to be threaded through all of them.
    /// Refreshed when downloads change and at launch — the query is one round
    /// trip and a grid draws hundreds of covers.
    private(set) var downloadedKeys: Set<String> = []

    func refreshDownloadedKeys() {
        downloadedKeys = (try? library?.downloadedBookKeys()) ?? []
    }

    public func open(bookRatingKey: String) {
        requestedBook = bookRatingKey
    }

    /// Bumped when a bookmark is added, renamed or removed.
    private(set) var bookmarkRevision = 0


    private(set) var nowPlayingTitle: String?
    private(set) var nowPlayingAuthor: String?
    private(set) var nowPlayingThumb: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    func start() async {
        // The delegate is asked whether closing the last window should quit, and
        // it has no other way to reach this store.
        AppDelegate.settings = menuBar
        // Quitting is the one moment this client can tell the server it has
        // gone, and on the Mac it is a moment the app controls: the delegate
        // blocks termination until this returns or a second passes.
        AppDelegate.willTerminate = { [weak self] in
            await self?.endSession()
        }

        identity = DeviceIdentity.current(store: keychain, version: appVersion)
        transport = PlexTransport(client: URLSessionHTTPClient.foreground(), identity: identity)

        do {
            database = try StoreLocation.open()
            library = LibraryStore(database: database)
            refreshDownloadedKeys()

            // Without this, CloudKit's silent pushes are never delivered and the
            // sync engine only learns about other devices when it next starts.
            RemoteNotifications.register()

            // And what to do when one arrives.
            RemoteNotifications.onPush = { [weak self] in
                await self?.cloud?.fetchChanges()
                self?.cloudChanged()
            }
            sync = SyncStore(database: database)
            sessions = SessionStore(database: database)

            // After the stores, because the driver needs the database, and not
            // awaited here: an iCloud account check is a network call and the
            // library should not wait behind it to appear.
            Task { await startCloudSync(database: database) }
            bookmarks = BookmarkStore(database: database)
            downloadStore = DownloadStore(database: database)
            downloads = BackgroundDownloadCoordinator(
                store: downloadStore,
                allowsExpensiveNetwork: Self.allowsExpensiveDownloads
            )
            // Transfers that finished while the app was not running are held by
            // the system and handed to a session with the same identifier.
            downloads.resumeAfterLaunch()
            // Once, at launch: files whose records are gone are dead weight, and
            // two recent fixes changed the name a download is stored under.
            downloads.pruneOrphanedFiles()
            // Trim the cover cache once, in the background. A sweep per write
            // would be a directory enumeration per cover.
            Task.detached { await ArtworkCache.shared.prune() }
        } catch {
            phase = .failed("Could not open the local database: \(error.localizedDescription)")
            return
        }

        wirePlayer()

        guard let token = keychain.read(.plexToken) else {
            phase = .signedOut
            return
        }
        await connect(token: token)
    }

    private func wirePlayer() {
        gatePlaybackWhenOffline()
        nowPlaying = NowPlayingController(player: player)
        player.onPositionChanged = { [weak self] bookRatingKey, absoluteMs in
            guard let self else { return }
            // Movement means the book is not finished, whatever it was a moment
            // ago — resuming, seeking back, or starting another book all arrive
            // here first.
            self.sessionEnded = false
            self.savePosition {
                try self.sync.recordPosition(bookRatingKey: bookRatingKey, absoluteMs: absoluteMs)
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
            // Finishing removes it from continue-listening.
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

    /// What "Reconnect" on the failure screen does — the exact same path a
    /// launch takes, not a lighter-weight retry of whatever step failed.
    /// `connect` re-discovers servers from scratch, which is deliberate: the
    /// failure that put somebody here is usually the server's address having
    /// changed, or a permission having been granted since, and re-running the
    /// discovery is what actually answers either case. Signed out is a
    /// different phase with its own screen, not something this button can
    /// reach — if the token itself is gone, retrying a connection with no
    /// token would only reproduce the same failure.
    func retryConnection() async {
        guard let token = keychain.read(.plexToken) else {
            phase = .signedOut
            return
        }
        await connect(token: token)
    }

    func connect(token: String) async {
        phase = .launching
        do {
            servers = try await PlexResourceDirectory(transport: transport).servers(token: token)
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
        let connection = try await ConnectionRacer(
            client: URLSessionHTTPClient.foreground(),
            identity: identity
        ).resolve(resource, fallbackToken: accountToken)

        let client = PlexServerClient(connection: connection, transport: transport)
        server = client
        keychain.write(resource.clientIdentifier, for: .serverIdentifier)
        try library.upsert(server: connection, name: resource.name)
        isDegraded = false

        sections = try await client.sections().filter(\.canContainAudiobooks)
        guard !sections.isEmpty else {
            phase = .failed("No music-type libraries on this server. Audiobooks live in a music library.")
            return
        }

        if let remembered = keychain.read(.sectionKey),
           let match = sections.first(where: { $0.key == remembered }) {
            try select(section: match, serverIdentifier: resource.clientIdentifier)
        } else if sections.count == 1 {
            try select(section: sections[0], serverIdentifier: resource.clientIdentifier)
        } else {
            phase = .choosingLibrary
        }
    }

    func select(section: PlexLibrarySection, serverIdentifier: String) throws {
        keychain.write(section.key, for: .sectionKey)
        sectionID = "\(serverIdentifier):\(section.key)"
        try library.upsert(section: section, serverID: serverIdentifier)
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

        // See the iOS copy of this function for why: the local library cache
        // is per-server and un-scoped in Continue Listening's query, so it
        // survives a sign-out on its own and bleeds into whatever server
        // signs in next. Progress and bookmarks are untouched — only the
        // stale library rows go.
        try? database?.purgeMetadataCache()
    }

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
    /// Unlabelled: naming it is a second step, offered afterwards, because the
    /// moment worth marking has usually passed by the time a keyboard appears.
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
    /// was unreachable.
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
        guard !isOffline, let server else { return }
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

    // MARK: - Now playing

    func setNowPlaying(title: String, author: String?, thumb: String?) {
        nowPlayingTitle = title
        nowPlayingAuthor = author
        nowPlayingThumb = thumb
        refreshNowPlayingInfo()
        // A book that has just started belongs in continue-listening now, not
        // after the next relaunch.
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

    // MARK: - Convenience

    /// Nil in offline mode, which is the whole mechanism.
    ///
    /// Every refresh, every collection fetch, every chapter upgrade and every
    /// progress push already begins `guard let sync = app.librarySync else
    /// { return }` — because each of them needs a server. Returning nil here
    /// switches all of them off at once, in one place, rather than adding an
    /// `if isOffline` to a dozen call sites and finding the thirteenth in
    /// airplane mode.
    var librarySync: LibrarySync? {
        guard !isOffline else { return nil }
        guard let server, let sectionID,
              let sectionKey = keychain.read(.sectionKey) else { return nil }
        return LibrarySync(
            client: server,
            store: library,
            progress: sync,
            downloadStore: downloadStore,
            sectionID: sectionID,
            sectionKey: sectionKey
        )
    }

    var progressSync: ProgressSync? {
        // Positions still record locally and stay queued in the outbox; they go
        // out on the next drain after this is switched off. Nothing is lost by
        // not pushing, and a push attempt on a plane is a timeout per book.
        guard !isOffline, let server else { return nil }
        return ProgressSync(client: server, store: sync, library: library)
    }
}

/// The VocalisBook menu, beside About and Settings.
///
/// Signing out is an account action, not a preference — it belongs where every
/// other Mac app puts one, not buried at the bottom of a settings window next to
/// the skip interval.
struct AccountCommands: Commands {
    let app: AppModel

    var body: some Commands {
        // In Library, not View.
        //
        // These were `after: .sidebar`, which puts them in the View menu — and
        // the View menu is removed now, taking ⌘R and ⌘⇧O with it. A shortcut
        // that stops working because a menu was tidied is a worse outcome than
        // the menu.
        //
        // A menu of their own, because they are not playback and there is
        // nowhere else they belong.
        CommandMenu("Library") {
            Button("Refresh Library") { app.libraryRefreshRequested += 1 }
                .keyboardShortcut("r", modifiers: .command)
            Button(app.isOffline ? "Go Online" : "Go Offline") { app.isOffline.toggle() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}

/// Menu bar commands.
///
/// These are also what makes the hardware media keys work: registering them here
/// and in `MPRemoteCommandCenter` covers both, and neither needs the
/// Accessibility permission a global event tap would.
struct PlaybackCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button(app.player.state == .playing ? "Pause" : "Play") {
                app.togglePlayPauseRespectingOffline()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(app.player.bookRatingKey == nil)

            Divider()

            Button("Skip Forward") { app.player.skip(bySeconds: app.player.skipIntervalSeconds) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Skip Back") { app.player.skip(bySeconds: -app.player.skipIntervalSeconds) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

            Divider()

            Button("Next Chapter") { app.player.skipToNextChapter() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            Button("Previous Chapter") { app.player.skipToPreviousChapter() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])

            Divider()

            // Resizes the window; the layout follows from that rather than the
            // other way round.
            Button("Mini Player") { WindowSizer.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}


/// What the menu bar item shows when clicked.
///
/// Transport and the current book, not a second copy of the library. Someone
/// opening this has the window closed and wants to pause, skip, or get the
/// window back — a menu is the wrong place to browse.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let title = app.nowPlayingTitle {
            Text(title)
            if let chapter = app.player.currentChapter {
                Text(chapter.title)
            }
            Divider()

            Button(app.player.state == .playing ? "Pause" : "Play") {
                app.togglePlayPauseRespectingOffline()
            }
            Button("Skip Back \(app.player.skipIntervalSeconds)s") {
                app.player.skip(bySeconds: -app.player.skipIntervalSeconds)
            }
            Button("Skip Forward \(app.player.skipIntervalSeconds)s") {
                app.player.skip(bySeconds: app.player.skipIntervalSeconds)
            }
            Divider()
        } else {
            Text("Nothing playing")
            Divider()
        }

        // Here as well as in Settings, because this is the menu somebody is
        // already in when they want the window out of the way — or in front of
        // everything else while they work.
        Toggle("Always on Top", isOn: Binding(
            get: { app.menuBar.floatsAboveOtherApps },
            set: { app.menuBar.floatsAboveOtherApps = $0 }
        ))

        Divider()

        Button("Open VocalisBook") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "library")
        }
        Button("Quit VocalisBook") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The About panel.
///
/// `CommandGroup(replacing: .appInfo)` rather than a window of our own: About is
/// a menu item the platform already puts in the right place, and replacing what
/// it does is less surprising than adding a second way in beside it.
///
/// The standard panel takes the version from the bundle by itself. What it
/// cannot know is who wrote this and where it lives, so those go in the credits.
struct AboutCommand: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppIdentity.name)") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .credits: credits,
                    // The panel shows `CFBundleName`; being explicit costs
                    // nothing and survives a rename of the target.
                    .applicationName: AppIdentity.name,
                    // "1.0.0 (42)", spelled out.
                    //
                    // The panel does show the version and build on its own, as
                    // "Version 1.0.0 (42)" — but only because those keys are in
                    // the bundle, and this is the one place a build number is
                    // read back to somebody over a message. Being explicit means
                    // the three apps say it the same way.
                    .applicationVersion: AppIdentity.version,
                    .version: AppIdentity.build,
                ])
            }
        }
    }

    /// Attributed because the panel takes nothing else, and a link has to be a
    /// link — a URL as plain text in an About box is something to retype.
    private var credits: NSAttributedString {
        let text = NSMutableAttributedString(
            string: "\(AppIdentity.summary)\n\nBy \(AppIdentity.author)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )

        let link = NSAttributedString(
            string: AppIdentity.repository.absoluteString,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: AppIdentity.repository,
            ]
        )
        text.append(link)

        text.append(NSAttributedString(
            string: "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))

        let mailto = URL(string: "mailto:\(AppIdentity.contactEmail)")!
        text.append(NSAttributedString(
            string: AppIdentity.contactEmail,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: mailto,
            ]
        ))

        text.append(NSAttributedString(
            string: "\n\n\(AppIdentity.disclaimer)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))

        return text
    }
}
