import SwiftUI
import Audiobooks
import PlatformShared

/// Home, on the Mac.
///
/// The same screen the phone and the television open on: what you were last
/// listening to, what else is part-way through, and what has arrived recently.
/// The Mac had none — it opened straight onto the grid — which meant the one
/// screen answering "where was I" existed on three platforms out of four.
///
/// It takes a closure rather than a binding, because the thing it opens is a
/// sidebar selection and that belongs to `LibraryView`.
struct HomeView: View {
    let open: (String, String) -> Void

    /// Called when somebody presses the streak.
    ///
    /// A card showing a streak, a week and an all-time total is a summary of
    /// the History screen, and a summary that cannot be opened is a dead end —
    /// the number is the most interesting thing on the screen and it did
    /// nothing.
    let showHistory: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = HomeModel()

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // What the app is doing. The Mac's refresh lives in the library
                // toolbar and starts the same work, so this screen should say so
                // as well rather than only the Series one.
                if let activity = app.activity {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(activity)
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                if let stats = model.stats, stats.currentStreak > 0 || stats.thisWeekSeconds > 0 {
                    Button(action: showHistory) {
                        StreakCard(stats: stats)
                    }
                    .buttonStyle(.plain)
                    .help("Show listening history")
                }

                // One section, not two. The book you were last in gets the large
                // treatment; the rest are the same list, not a lesser category.
                if !model.visible(app: app).isEmpty {
                    section("Continue listening") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(model.visible(app: app), id: \.ratingKey) { book in
                                Button { open(book.ratingKey, book.title) } label: { BookTile(book: book) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Between what you are in the middle of and what the server has
                // acquired: ordered by how recently it concerns you.
                if !model.recentlyFinished.isEmpty {
                    section("Recently listened to") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(model.recentlyFinished, id: \.ratingKey) { book in
                                Button { open(book.ratingKey, book.title) } label: { BookTile(book: book) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !model.recentlyAdded.isEmpty {
                    section("Recently added") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(model.recentlyAdded, id: \.ratingKey) { book in
                                Button { open(book.ratingKey, book.title) } label: { BookTile(book: book) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Whatever the agent most recently had something new to say
                // about — distinct from "Recently added" above, which is
                // about when a book joined the library rather than when its
                // metadata last changed. A book already here for months
                // still surfaces the day it gets a work identity or a
                // narrator it didn't have before.
                if !model.recentlyUpdated.isEmpty {
                    section("Recently updated") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(model.recentlyUpdated, id: \.ratingKey) { book in
                                Button { open(book.ratingKey, book.title) } label: { BookTile(book: book) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !model.unabridged.isEmpty {
                    section("Unabridged") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(model.unabridged, id: \.ratingKey) { book in
                                Button { open(book.ratingKey, book.title) } label: { BookTile(book: book) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !model.fullCastOrDramatized.isEmpty {
                    section("Full Cast & Dramatized") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(model.fullCastOrDramatized, id: \.ratingKey) { book in
                                Button { open(book.ratingKey, book.title) } label: { BookTile(book: book) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !model.shortListens.isEmpty {
                    section("Short Listens") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(model.shortListens, id: \.ratingKey) { book in
                                Button { open(book.ratingKey, book.title) } label: { BookTile(book: book) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !model.longListens.isEmpty {
                    section("Long Listens") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(model.longListens, id: \.ratingKey) { book in
                                Button { open(book.ratingKey, book.title) } label: { BookTile(book: book) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if model.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet",
                        systemImage: "books.vertical",
                        description: Text("Your library appears once it has been fetched.")
                    )
                    .padding(.top, 60)
                }
            }
            .padding(20)
        }
        .background(theme.background)
        // Restarted when offline mode changes, because that changes the query.
        .task(id: app.isOffline) { await model.observe(app: app) }
        .task {
            model.reload(app: app)
            // Ask on arrival rather than waiting for the next poll: coming to
            // this screen is the moment somebody wants it right.
            await app.cloud?.fetchChanges()
        }
        // This is the screen that has to move on its own, so it asks the poll
        // to run quickly while it is up and lets it back off when it is not.
        .onAppear { app.beginLiveUpdates() }
        .onDisappear { app.endLiveUpdates() }
        .onChange(of: app.libraryRevision) { _, _ in model.reload(app: app) }
        // No player observers here any more.
        //
        // The playing book is dropped by `visible(app:)`, which reads the player
        // directly — so SwiftUI re-renders when playback changes without anything
        // going back to the database. These two called `reload`, which no longer
        // touches the list at all.
        .onChange(of: app.isOffline) { _, _ in model.reload(app: app) }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.text)
            content()
        }
    }
}

/// `@MainActor`, like every other model in this app.
///
/// It matters more here than it looks. `observe(app:)` sits in a `for await`
/// loop and assigns to `inProgress` after every suspension — under Swift 6 that
/// is a data race unless the type is isolated, and the compiler says so.
///
/// iOS carried the annotation already, which is why the Mac was the build that
/// failed: the same code, one platform missing one line.
@MainActor
@Observable
final class HomeModel {
    /// Straight from the database, and re-delivered whenever it changes.
    ///
    /// Nothing tells this list to reload. A position written here, a record
    /// arriving from iCloud, a position adopted from Plex, a purge — all of them
    /// are writes to `progress`, and all arrive here identically.
    private(set) var inProgress: [BookRecord] = []
    private(set) var recentlyAdded: [BookRecord] = []

    /// Books whose metadata changed most recently — see
    /// `LibraryStore.recentlyUpdated` for why this is not the same list as
    /// `recentlyAdded`.
    private(set) var recentlyUpdated: [BookRecord] = []

    private(set) var unabridged: [BookRecord] = []
    private(set) var fullCastOrDramatized: [BookRecord] = []
    private(set) var shortListens: [BookRecord] = []
    private(set) var longListens: [BookRecord] = []

    /// Books finished, most recently first.
    ///
    /// The other end of Continue listening. That list is what is in progress and
    /// empties as books are finished; without this, finishing one is the moment
    /// it disappears from the app entirely.
    private(set) var recentlyFinished: [BookRecord] = []
    private(set) var stats: ListeningStats?

    /// Whether Home has nothing at all to show.
    ///
    /// All three lists, not two. A library where everything has been finished
    /// has no books in progress and nothing newly added, and would have shown
    /// the "nothing here yet" message above a screen full of finished books.
    var isEmpty: Bool {
        inProgress.isEmpty && recentlyAdded.isEmpty && recentlyFinished.isEmpty && recentlyUpdated.isEmpty
            && unabridged.isEmpty && fullCastOrDramatized.isEmpty && shortListens.isEmpty && longListens.isEmpty
    }

    /// The list as shown: the observed rows, minus the one being played.
    ///
    /// Filtered here rather than in the query. Whether the player holds a book is
    /// not in the database, and a query depending on it would have to be rebuilt
    /// every time playback changed.
    func visible(app: AppModel) -> [BookRecord] {
        inProgress.filter {
            app.player.state != .playing || $0.ratingKey != app.player.bookRatingKey
        }
    }

    /// Follows the list for as long as the screen is up. `.task` starts and
    /// cancels it, so there is nothing to remember to tear down.
    func observe(app: AppModel) async {
        guard let library = app.library else { return }
        do {
            for try await books in library.continueListeningStream(
                downloadedOnly: app.isOffline
            ) {
                inProgress = books
            }
        } catch {
            // The observation stopped. The list keeps what it last held rather
            // than emptying because a query failed, and the next appearance
            // starts a fresh one.
        }
    }

    @MainActor
    func reload(app: AppModel) {
        // Emptied rather than left, when there is nothing to read.
        //
        // A bare `return` here keeps whatever was last loaded on screen. After
        // clearing the cache the database is empty and `sectionID` is nil, so
        // this guard fired and the old rows stayed visible — the list was a
        // memory of a database that no longer held any of it.
        guard let library = app.library, let sectionID = app.sectionID else {
            recentlyAdded = []
            recentlyUpdated = []
            recentlyFinished = []
            unabridged = []
            fullCastOrDramatized = []
            shortListens = []
            longListens = []
            stats = nil
            return
        }

        // The playing book is not somewhere to return to while you are there.
        // The in-progress list is not read here: it is observed, and arrives on
        // its own. This is for the parts that only change when the library does.
        recentlyAdded = (try? library.recentlyAdded(
            sectionID: sectionID,
            limit: 12,
            downloadedOnly: app.isOffline
        )) ?? []

        recentlyUpdated = (try? library.recentlyUpdated(
            sectionID: sectionID,
            limit: 12,
            downloadedOnly: app.isOffline
        )) ?? []

        unabridged = (try? library.unabridged(
            sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline
        )) ?? []
        fullCastOrDramatized = (try? library.fullCastOrDramatized(
            sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline
        )) ?? []
        shortListens = (try? library.shortListens(
            sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline
        )) ?? []
        longListens = (try? library.longListens(
            sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline
        )) ?? []

        recentlyFinished = (try? library.recentlyFinished(
            limit: 12,
            downloadedOnly: app.isOffline
        )) ?? []

        stats = try? app.sessions.stats(sectionID: app.sectionID)
    }
}
