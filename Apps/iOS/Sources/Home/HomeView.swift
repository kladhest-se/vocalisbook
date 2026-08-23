import SwiftUI
import Audiobooks
import Platform
import PlatformShared

/// The home screen.
///
/// One book is the point of opening an audiobook app, so one book gets the
/// space: cover, where you are, how much is left, and a resume control wide
/// enough to hit without looking. Everything else is a row beneath it.
///
/// The shape is borrowed from Saga, which gets this right — the hero card, the
/// smaller in-progress row under it, then the rest of the library. What is not
/// borrowed is the streak counter: nothing here records listening sessions yet,
/// and a number that is always zero is worse than no number.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = HomeModel()
    @Binding var selection: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// How wide a cover is in Home's horizontal rows.
    ///
    /// 124 is a phone tile. On an iPad the same number gives a row of small
    /// covers with a great deal of air around them — the screenshot that
    /// prompted this looked like a phone layout someone had stretched, because
    /// it was.
    private var tileWidth: CGFloat { sizeClass == .regular ? 180 : 124 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
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

                // The streak first, as the thing you glance at. It only appears
                // once there is something to say — a card reading "0-day streak"
                // on a fresh install is worse than no card.
                if let stats = model.stats, stats.currentStreak > 0 || stats.thisWeekSeconds > 0 {
                    NavigationLink(value: HomeRoute.history) {
                        StreakCard(stats: stats)
                    }
                    .buttonStyle(.plain)
                }

                // One section, not two.
                //
                // The book you were last in got a card with a Resume button and
                // everything else got a separate heading called "Also in
                // progress" — which is the same idea twice, and made the second
                // group look like a lesser category rather than the rest of the
                // same list. They are all books you are part-way through.
                //
                // The card stays, because resuming is the one thing this screen
                // exists for and a button beats a tile. The rest sit under it in
                // a row that scrolls sideways for as many as there are.
                if !model.visible(app: app).isEmpty {
                    Section(title: "Continue listening") {
                        VStack(alignment: .leading, spacing: 16) {
                            if let current = model.current(app: app) {
                                ContinueListeningCard(book: current, progress: model.currentProgress) {
                                    selection = current.ratingKey
                                }
                                // Capped rather than stretched. A 116pt cover
                                // beside two lines of text, pulled across a
                                // 13-inch screen, is mostly gap.
                                .frame(maxWidth: sizeClass == .regular ? 620 : .infinity,
                                       alignment: .leading)
                            }

                            if !model.alsoInProgress(app: app).isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(alignment: .top, spacing: 16) {
                                        ForEach(model.alsoInProgress(app: app), id: \.ratingKey) { book in
                                            Button { selection = book.ratingKey } label: {
                                                BookTile(book: book).frame(width: tileWidth)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                }
                                .padding(.horizontal, -20)
                            }
                        }
                    }
                }

                // Below Continue listening and above Recently added.
                //
                // Order by how recently it concerns you: what you are in the
                // middle of, what you have just finished, and then what the
                // server has acquired — which is the newest to the library and
                // the least likely to be the reason you opened the app.
                if !model.recentlyFinished.isEmpty {
                    Section(title: "Recently listened to") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(model.recentlyFinished, id: \.ratingKey) { book in
                                    Button { selection = book.ratingKey } label: {
                                        BookTile(book: book).frame(width: tileWidth)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }
                }

                if !model.recentlyAdded.isEmpty {
                    Section(title: "Recently added") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(model.recentlyAdded, id: \.ratingKey) { book in
                                    Button { selection = book.ratingKey } label: {
                                        BookTile(book: book).frame(width: tileWidth)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }
                }

                // Distinct from "Recently added" above: this is about when
                // the agent last had something new to say about a book, not
                // when it joined the library. One already here for months
                // still surfaces the day it gets a work identity or a
                // narrator it didn't have before.
                if !model.recentlyUpdated.isEmpty {
                    Section(title: "Recently updated") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(model.recentlyUpdated, id: \.ratingKey) { book in
                                    Button { selection = book.ratingKey } label: {
                                        BookTile(book: book).frame(width: tileWidth)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }
                }

                if !model.unabridged.isEmpty {
                    Section(title: "Unabridged") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(model.unabridged, id: \.ratingKey) { book in
                                    Button { selection = book.ratingKey } label: {
                                        BookTile(book: book).frame(width: tileWidth)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }
                }

                if !model.fullCastOrDramatized.isEmpty {
                    Section(title: "Full Cast & Dramatized") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(model.fullCastOrDramatized, id: \.ratingKey) { book in
                                    Button { selection = book.ratingKey } label: {
                                        BookTile(book: book).frame(width: tileWidth)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }
                }

                if !model.shortListens.isEmpty {
                    Section(title: "Short Listens") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(model.shortListens, id: \.ratingKey) { book in
                                    Button { selection = book.ratingKey } label: {
                                        BookTile(book: book).frame(width: tileWidth)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }
                }

                if !model.longListens.isEmpty {
                    Section(title: "Long Listens") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(model.longListens, id: \.ratingKey) { book in
                                    Button { selection = book.ratingKey } label: {
                                        BookTile(book: book).frame(width: tileWidth)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }
                }

                if model.isEmpty {
                    EmptyLibraryView(isRefreshing: model.isRefreshing)
                }
            }
            .padding(20)
            .padding(.bottom, 90)
        }
        .background(theme.background.ignoresSafeArea())
        // Pull to refresh, and nothing else.
        //
        // There was a button here that ran a full library sync with no progress
        // shown, so it looked like nothing had happened for as long as it took.
        // A control that appears to do nothing is worse than the gesture alone.
        // Series tags come with the library sync now, which is where they should
        // always have come from.
        .refreshable { await model.refresh(app: app) }
        // Restarted when offline mode changes, because that changes the query.
        .task(id: app.isOffline) { await model.observe(app: app) }
        .task {
            model.reload(app: app)
            // Ask on arrival rather than waiting for the next poll: coming to
            // this screen is the moment somebody wants it right.
            await app.cloud?.fetchChanges()
            if model.isEmpty { await model.refresh(app: app) }
        }
        // Starting or finishing a book changes what belongs here.
        // Starting or stopping a book changes what belongs in Continue
        // listening, and nothing else bumps a revision when it does — the
        // player changing is its own event.
        // No player observers here any more.
        //
        // The playing book is dropped by `visible(app:)`, which reads the player
        // directly — so SwiftUI re-renders when playback changes without anything
        // going back to the database. These two called `reload`, which no longer
        // touches the list at all.
        // This is the screen that has to move on its own, so it asks the poll
        // to run quickly while it is up and lets it back off when it is not.
        .onAppear { app.beginLiveUpdates() }
        .onDisappear { app.endLiveUpdates() }
        .onChange(of: app.libraryRevision) { _, _ in model.reload(app: app) }
        .onChange(of: app.historyRevision) { _, _ in model.reload(app: app) }
    }

    private struct Section<Content: View>: View {
        let title: String
        @ViewBuilder var content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.text)
                content
            }
        }
    }
}

/// The hero card: cover on the left, position on the right, resume across the
/// bottom edge to edge.
struct ContinueListeningCard: View {
    let book: BookRecord
    let progress: ProgressRecord?
    let onTap: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    private var fraction: Double {
        guard let progress, let total = book.durationMs, total > 0 else { return 0 }
        return min(Double(progress.absoluteMs) / Double(total), 1)
    }

    private var remaining: String? {
        guard let progress, let total = book.durationMs, total > progress.absoluteMs else { return nil }
        return Format.approximateDuration(ms: total - progress.absoluteMs) + " left"
    }

    var body: some View {
        // No heading of its own: the section around it carries one now, and two
        // in a row read as a mistake.
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    CoverImage(thumb: book.thumb)
                        .frame(width: 116, height: 116)
                        .clipShape(.rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title)
                            .font(.headline)
                            .foregroundStyle(theme.text)
                            .lineLimit(2)
                        if let author = book.author {
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        HStack(alignment: .firstTextBaseline) {
                            if let remaining {
                                Text(remaining)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(theme.text)
                            }
                            Spacer()
                            Text("\(Int(fraction * 100))%")
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText)
                        }
                        ProgressBar(fraction: fraction)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)

                Button(action: onTap) {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        Text("Resume listening").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(theme.background)
                    .background(theme.accent)
                }
                .buttonStyle(.plain)
            }
            .background(theme.surface)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.accent.opacity(0.35), lineWidth: 1)
            )
        }
    }
}

struct ProgressBar: View {
    let fraction: Double
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 5)
    }
}

struct EmptyLibraryView: View {
    let isRefreshing: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(theme.tertiaryText)
            Text(isRefreshing ? "Fetching your library…" : "No books yet")
                .font(.headline)
                .foregroundStyle(theme.text)
            if !isRefreshing {
                Text("Pull down to fetch your library from Plex.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

@MainActor
@Observable
final class HomeModel {
    /// Straight from the database, and re-delivered whenever it changes.
    ///
    /// Nothing tells this list to reload. A position written here, a record
    /// arriving from iCloud, a position adopted from Plex, a purge — all of them
    /// are writes to `progress`, and all of them arrive here identically.
    private(set) var inProgress: [BookRecord] = []
    private(set) var currentProgress: ProgressRecord?
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
    private(set) var isRefreshing = false

    /// Whether this refresh has already put something on screen.
    ///
    /// On the model rather than in the closure: `onPage` is `@Sendable`, and
    /// mutating a captured local from inside it is exactly what Swift 6
    /// forbids. The model is already main-actor isolated, which is also where
    /// the reload has to happen.
    private var hasShownAPage = false
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
    /// every time playback changed — this way the list reacts to play and pause
    /// without touching the database at all.
    func visible(app: AppModel) -> [BookRecord] {
        inProgress.filter {
            app.player.state != .playing || $0.ratingKey != app.player.bookRatingKey
        }
    }

    func current(app: AppModel) -> BookRecord? { visible(app: app).first }
    func alsoInProgress(app: AppModel) -> [BookRecord] { Array(visible(app: app).dropFirst()) }

    /// Follows the list for as long as the screen is up.
    ///
    /// `.task` cancels this when the view goes away and starts it again when it
    /// comes back, which is the whole lifecycle — there is nothing to remember
    /// to tear down.
    func observe(app: AppModel) async {
        guard let library = app.library else { return }
        do {
            for try await books in library.continueListeningStream(
                limit: 12,
                downloadedOnly: app.isOffline
            ) {
                inProgress = books
                currentProgress = books.first.flatMap {
                    try? app.sync.progress(bookRatingKey: $0.ratingKey)
                }
            }
        } catch {
            // The observation stopped. The list keeps whatever it last held,
            // which is better than emptying a screen because a query failed, and
            // the next appearance starts a fresh one.
        }
    }

    /// Reads from the local store only. Browsing never waits on the network —
    /// that is the entire reason the cache exists.
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

        // Not the one that is playing.
        //
        // "Continue listening" is a way back into a book you left. The book in
        // your ears is not one you left, and it is already on screen twice — in
        // the mini player and, once tapped, in the player itself. Showing it a
        // third time as somewhere to resume reads as the app not knowing what it
        // is doing.
        // The in-progress list is not read here: it is observed, and arrives on
        // its own. This is for the parts that only change when the library does.
        recentlyAdded = (try? library.recentlyAdded(sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline)) ?? []
        recentlyUpdated = (try? library.recentlyUpdated(sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline)) ?? []
        recentlyFinished = (try? library.recentlyFinished(limit: 12, downloadedOnly: app.isOffline)) ?? []
        unabridged = (try? library.unabridged(sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline)) ?? []
        fullCastOrDramatized = (try? library.fullCastOrDramatized(sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline)) ?? []
        shortListens = (try? library.shortListens(sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline)) ?? []
        longListens = (try? library.longListens(sectionID: sectionID, limit: 12, downloadedOnly: app.isOffline)) ?? []
        stats = try? app.sessions.stats(sectionID: app.sectionID)
    }

    func refresh(app: AppModel) async {
        guard let sync = app.librarySync, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; app.setActivity(nil) }
        do {
            // Reloaded on the first page and then not again until the end.
            //
            // Every page replaced the whole list: a re-query and a fresh array
            // for each 200 books, so a library of a few thousand rebuilt its
            // grid a dozen times during one refresh. Each rebuild relays out the
            // grid, and doing that under a moving finger is what a stutter is.
            //
            // The first page still lands immediately, because an empty library
            // that stays empty for twenty seconds looks broken. After that the
            // count in the progress line is the thing that moves, which costs
            // nothing.
            hasShownAPage = false
            try await sync.refreshBooks(
                onPage: { _, _ in
                    Task { @MainActor in
                        guard !self.hasShownAPage else { return }
                        self.hasShownAPage = true
                        self.reload(app: app)
                    }
                },
                // Reported here too, and this is the screen it matters on.
                //
                // Series progress was wired into the Library refresh and not this
                // one — and pulling down on Home is the gesture people are told
                // to use, so the one screen that stayed silent for a minute was
                // the one being recommended.
                onSeries: { done, total in
                    Task { @MainActor in
                        app.setActivity(
                            done >= total ? nil : "Fetching series… \(done) of \(total)"
                        )
                    }
                }
            )
            app.clearDegraded()
            _ = try? await app.progressSync?.drain()
        } catch {
            app.handle(error)
        }
        reload(app: app)
    }
}
