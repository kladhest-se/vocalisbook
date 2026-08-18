import SwiftUI
import Audiobooks
import PlatformShared

/// Home, on the television.
///
/// What the phone and the Mac have shown all along and this platform did not:
/// what you were listening to, what else is part-way through, and what has
/// arrived recently.
///
/// Home was the library here — the whole grid, with a search field — and Browse
/// was the same grid without one. Two screens showing every book, and nowhere
/// showing where you left off.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = HomeModel()

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 48)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    DegradedBanner()

                    // What the app is doing, where somebody pulled to make it do it.
                    //
                    // Only the Series screen showed this, and pulling down here is the
                    // gesture that starts the work — so the screen somebody was looking
                    // at while it ran was the one saying nothing.
                    if let activity = app.activity {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(activity)
                                .font(.footnote)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }


                    // Only once there is something to say — a card reading
                    // "0-day streak" on a fresh install is worse than no card.
                    if let stats = model.stats,
                       stats.currentStreak > 0 || stats.thisWeekSeconds > 0 {
                        // Selects the History tab rather than pushing it:
                        // pushing made the tab bar collapse and return, which
                        // reads as the menu moving rather than as going
                        // somewhere.
                        Button {
                            app.selectedTab = .history
                        } label: {
                            StreakCard(stats: stats)
                        }
                        .buttonStyle(.card)
                    }

                    if !model.visible(app: app).isEmpty {
                        section("Continue listening", books: model.visible(app: app))
                    }

                    // Between what you are in the middle of and what the server
                    // has acquired.
                    if !model.recentlyFinished.isEmpty {
                        section("Recently listened to", books: model.recentlyFinished)
                    }

                    if !model.recentlyAdded.isEmpty {
                        section("Recently added", books: model.recentlyAdded)
                    }

                    if model.isEmpty {
                        ContentUnavailableView(
                            "Nothing here yet",
                            systemImage: "books.vertical",
                            description: Text("Your library appears once it has been fetched.")
                        )
                        .padding(.top, 80)
                    }
                }
                .padding(16)
                .padding(.bottom, 90)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationDestination(for: String.self) { BookDetailView(ratingKey: $0) }
        }
        // No `id:` here, unlike the phone and the Mac.
        //
        // Theirs restarts the observation when offline mode changes, because
        // that changes the query. A television has no offline mode and no
        // downloads — it streams or it does nothing — so there is nothing for
        // the query to depend on and nothing to restart it for.
        .task { await model.observe(app: app) }
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
        .onChange(of: app.historyRevision) { _, _ in model.reload(app: app) }
        // No player observers here any more.
        //
        // The playing book is dropped by `visible(app:)`, which reads the player
        // directly — so SwiftUI re-renders when playback changes without anything
        // going back to the database. These two called `reload`, which no longer
        // touches the list at all.
    }

    /// A titled grid rather than a horizontal row.
    ///
    /// A television scrolls vertically by focus, and a row that scrolls sideways
    /// needs a separate horizontal move to reach its end — fine on a phone with
    /// a thumb, tiresome with a remote.
    @ViewBuilder
    private func section(_ title: String, books: [BookRecord]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.text)

            LazyVGrid(columns: columns, spacing: 48) {
                ForEach(books, id: \.ratingKey) { book in
                    NavigationLink(value: book.ratingKey) { BookTile(book: book) }
                        .buttonStyle(.card)
                }
            }
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
        inProgress.isEmpty && recentlyAdded.isEmpty && recentlyFinished.isEmpty
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
            for try await books in library.continueListeningStream() {
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
            recentlyFinished = []
            stats = nil
            return
        }

        // Not the book that is playing: it is not somewhere to return to while
        // you are already there.
        // The in-progress list is not read here: it is observed, and arrives on
        // its own. This is for the parts that only change when the library does.
        recentlyAdded = (try? library.recentlyAdded(sectionID: sectionID, limit: 12)) ?? []
        recentlyFinished = (try? library.recentlyFinished(limit: 12)) ?? []
        stats = try? app.sessions.stats(sectionID: app.sectionID)
    }
}
