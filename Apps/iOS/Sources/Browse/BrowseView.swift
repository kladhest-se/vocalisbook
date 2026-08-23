import SwiftUI
import Audiobooks
import PlatformShared

/// One screen, four ways in: writers, narrators, series, genres.
///
/// These were four separate tabs, which cost four of the five iOS allows and
/// left the tab bar describing the *shape* of the data rather than what anyone
/// came to do. They are all the same screen — a list of names, each with a
/// cover and a count, and a set of books behind it — differing only in which
/// table the names come from. Folding them together freed two tabs and made
/// that sameness explicit rather than something four near-identical files
/// happened to agree on.
///
/// The switch is a title menu rather than a segmented control. A segmented
/// control works for two and falls apart at four: the labels shrink to fit,
/// and it takes a strip across the top of every list permanently. Tapping the
/// navigation title is the pattern iOS already uses for exactly this — Mail's
/// mailbox picker, Files' locations — and it costs no vertical space at all.
/// The title says which one you are in, so the affordance and the label are
/// the same object.
///
/// Writers, not authors. The name of this list changed with what feeds it:
/// `LibraryStore.authors` reads the metadata agent's `Mood` credits only, and
/// no longer unions in Plex's album artist, which in an audiobook library is
/// as often the narrator as the writer. A book the agent has not matched
/// therefore has no writer and appears under nobody — deliberately, since the
/// alternative was a list of writers with narrators in it.
struct BrowseView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var mode: Mode = .writers
    @State private var writers: [AuthorSummary] = []
    @State private var narrators: [NarratorSummary] = []
    @State private var series: [SeriesSummary] = []
    @State private var genres: [GenreSummary] = []
    @State private var search = ""

    enum Mode: String, CaseIterable, Hashable {
        case writers = "Writers"
        case narrators = "Narrators"
        case series = "Series"
        case genres = "Genres"

        /// The symbols the tabs used, kept rather than reinvented: three of
        /// these were on the tab bar until this screen absorbed them, and a
        /// person who learned them there should not have to learn them again.
        var symbol: String {
            switch self {
            case .writers: "person"
            case .narrators: "person.wave.2"
            case .series: "square.stack"
            case .genres: "theatermasks"
            }
        }

        /// Singular — it goes in a search field, where the plural reads as a
        /// claim about what will be found rather than what to type.
        var searchPrompt: String {
            switch self {
            case .writers: "Writer"
            case .narrators: "Narrator"
            case .series: "Series"
            case .genres: "Genre"
            }
        }
    }

    /// Name, cover, book count — the one shape all four summaries share, so a
    /// single row and a single filter serve every mode without any of the four
    /// types needing to know about the others.
    private struct Row: Identifiable {
        let name: String
        let bookCount: Int
        let cover: String?
        var id: String { name }
    }

    private var rows: [Row] {
        let source: [Row]
        switch mode {
        case .writers:
            source = writers.map { Row(name: $0.name, bookCount: $0.bookCount, cover: $0.covers.first) }
        case .narrators:
            source = narrators.map { Row(name: $0.name, bookCount: $0.bookCount, cover: $0.covers.first) }
        case .series:
            source = series.map { Row(name: $0.name, bookCount: $0.bookCount, cover: $0.covers.first) }
        case .genres:
            source = genres.map { Row(name: $0.name, bookCount: $0.bookCount, cover: $0.covers.first) }
        }
        return search.isEmpty
            ? source
            : source.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(rows) { row in
                NavigationLink(value: BrowseRoute(name: row.name, mode: mode)) {
                    HStack(spacing: 12) {
                        // One cover, not the four the television shows. A 2×2
                        // collage at this size is mush; the point here is only
                        // to make the row scannable by something other than
                        // reading it.
                        CoverImage(thumb: row.cover)
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Text(row.bookCount == 1 ? "1 book" : "\(row.bookCount) books")
                                .font(.footnote)
                                .foregroundStyle(theme.tertiaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.name)
                    .accessibilityValue(row.bookCount == 1 ? "1 book" : "\(row.bookCount) books")
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            // Pulling down here did nothing at all: these lists are derived
            // from the cached books, so they only change when the library is
            // fetched — and these screens never fetched. Every other tab
            // refreshes; a gesture that works in three places and silently does
            // nothing in the fourth is worse than one that is absent everywhere.
            .refreshable {
                if let sync = app.librarySync {
                    _ = try? await sync.refreshBooks()
                }
                reload()
            }
            .searchable(text: $search, prompt: mode.searchPrompt)
            .navigationTitle(mode.rawValue)
            // A `Picker`, not four `Button`s: the picker draws the checkmark
            // beside the current mode, which is the thing that makes a title
            // menu legible as a switch rather than a list of places to go.
            .toolbarTitleMenu {
                Picker("Browse", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.inline)
            }
            .accountToolbar()
            .navigationDestination(for: BrowseRoute.self) { route in
                switch route.mode {
                case .writers: AuthorBooksView(author: route.name)
                case .narrators: NarratorBooksView(narrator: route.name)
                case .series: SeriesBooksView(series: route.name)
                case .genres: GenreBooksView(genre: route.name)
                }
            }
            .overlay { emptyState }
        }
        .task { reload() }
        .onChange(of: app.libraryRevision) { _, _ in reload() }
        .onChange(of: app.isOffline) { _, _ in reload() }
        // Cleared on the way out, not carried across.
        //
        // A search for "Pratchett" left in the field while switching to Genres
        // filters every genre away and shows the empty state, which reads as a
        // library with no genres in it rather than a filter still applied.
        .onChange(of: mode) { _, _ in
            search = ""
            reload()
        }
    }

    /// What an empty list means, which differs by mode.
    ///
    /// Three of these are not "nothing yet" but "nothing, and refreshing will
    /// not change that" — they are metadata problems with metadata fixes, and
    /// saying so is the difference between a person fixing their agent and a
    /// person pulling to refresh forever.
    @ViewBuilder
    private var emptyState: some View {
        if mode == .series, let activity = app.activity {
            // Working, and saying so.
            //
            // Fetching series is a request per series, which on a large library
            // is long enough that an empty screen reads as a broken one. The
            // "No series" message below is true only when nothing is being
            // fetched — showing it during the fetch would be the app
            // contradicting itself a minute later.
            VStack(spacing: 12) {
                ProgressView()
                Text(activity)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }
        } else if rows.isEmpty {
            switch mode {
            case .writers:
                ContentUnavailableView(
                    "No writers",
                    systemImage: "person",
                    description: Text(
                        "Writers come from the metadata agent's credits, not from the "
                        + "album artist Plex holds. Books it has not matched carry none."
                    )
                )
            case .narrators:
                ContentUnavailableView(
                    "No narrators",
                    systemImage: "person.wave.2",
                    description: Text(
                        "Narrators come from the metadata agent. Books it has not "
                        + "matched carry none."
                    )
                )
            case .series:
                ContentUnavailableView(
                    "No series",
                    systemImage: "square.stack",
                    description: Text(
                        "Series come from the metadata agent. Books it has not "
                        + "matched, or that belong to no series, carry none."
                    )
                )
            case .genres:
                ContentUnavailableView(
                    "No genres",
                    systemImage: "theatermasks",
                    description: Text(
                        "Plex tags books with genres once an agent has matched them. "
                        + "Books it has not matched carry none."
                    )
                )
            }
        }
    }

    /// Only the mode on screen.
    ///
    /// Loading all four would run four queries to show one list, on a signal
    /// that fires on every library change. These are local reads and switching
    /// modes calls this again, so the cost of the miss is a frame, not a
    /// request.
    private func reload() {
        // Emptied rather than left, when there is nothing to read.
        //
        // A bare `return` here keeps whatever was last loaded on screen. After
        // clearing the cache the database is empty and `sectionID` is nil, so
        // this guard fired and the old rows stayed visible — the list was a
        // memory of a database that no longer held any of it.
        guard let library = app.library, let sectionID = app.sectionID else {
            writers = []
            narrators = []
            series = []
            genres = []
            return
        }

        let offline = app.isOffline
        switch mode {
        case .writers:
            writers = (try? library.authors(sectionID: sectionID, downloadedOnly: offline)) ?? []
        case .narrators:
            narrators = (try? library.narrators(sectionID: sectionID, downloadedOnly: offline)) ?? []
        case .series:
            series = (try? library.series(sectionID: sectionID, downloadedOnly: offline)) ?? []
        case .genres:
            genres = (try? library.genres(sectionID: sectionID, downloadedOnly: offline)) ?? []
        }
    }
}

/// A row on the browse list, whichever kind it is.
///
/// One type carrying the mode rather than four route types, for the reason the
/// old `PersonRoute` carried it: a name alone cannot say which detail screen to
/// push, and a writer and a genre sharing a name would otherwise collide. It
/// also settles the older problem `GenreRoute` and `SeriesRoute` existed for —
/// a genre called "1234" is not the same destination as the book with that
/// rating key, because this is not a `String`.
struct BrowseRoute: Hashable {
    let name: String
    let mode: BrowseView.Mode
}
