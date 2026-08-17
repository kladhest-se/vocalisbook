import SwiftUI
import Audiobooks
import PlatformShared

/// Series, from the metadata agent's own tags.
///
/// Shaped like `GenresView`: a list of names with a cover and a count, and the
/// books behind each. The difference is that these have an *order* — the agent
/// records a position per book, and a series read out of order is the one
/// grouping where that matters.
///
/// Not from Plex collections. A collection is whatever somebody dragged into it,
/// in whatever order; a `Series:` Mood is something the metadata states. The
/// agent's contract is explicit that collections are user data and a series
/// should not be derived from them alone.
struct SeriesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var series: [SeriesSummary] = []
    @State private var search = ""

    private var shown: [SeriesSummary] {
        search.isEmpty
            ? series
            : series.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { entry in
                NavigationLink(value: SeriesRoute(name: entry.name)) {
                    HStack(spacing: 12) {
                        CoverImage(thumb: entry.covers.first)
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(entry.bookCount == 1 ? "1 book" : "\(entry.bookCount) books")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(entry.name)
                .accessibilityValue(entry.bookCount == 1 ? "1 book" : "\(entry.bookCount) books")
                .listRowBackground(theme.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .refreshable {
                if let sync = app.librarySync {
                    _ = try? await sync.refreshBooks()
                }
                reload()
            }
            .searchable(text: $search, prompt: "Series")
            .navigationTitle("Series")
            .accountToolbar()
            .navigationDestination(for: SeriesRoute.self) { SeriesBooksView(series: $0.name) }
            .overlay {
                if let activity = app.activity {
                    // Working, and saying so.
                    //
                    // Fetching these is a request per series, which on a large
                    // library is long enough that an empty screen reads as a
                    // broken one. The "No series" message below is true only
                    // when nothing is being fetched — showing it during the
                    // fetch would be the app contradicting itself a minute
                    // later.
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(activity)
                            .font(.callout)
                            .foregroundStyle(theme.secondaryText)
                    }
                } else if series.isEmpty {
                    // Named for the cause. A library no agent has matched carries
                    // no series tags, and refreshing here will never produce any.
                    ContentUnavailableView(
                        "No series",
                        systemImage: "books.vertical",
                        description: Text(
                            "Series come from the metadata agent. Books it has not "
                            + "matched, or that belong to no series, carry none."
                        )
                    )
                }
            }
        }
        .task { reload() }
        .onChange(of: app.libraryRevision) { _, _ in reload() }
        .onChange(of: app.isOffline) { _, _ in reload() }
    }

    private func reload() {
        guard let library = app.library, let sectionID = app.sectionID else {
            series = []
            return
        }
        series = (try? library.series(sectionID: sectionID, downloadedOnly: app.isOffline)) ?? []
    }
}

/// One series, in reading order.
struct SeriesBooksView: View {
    let series: String

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var entries: [SeriesEntry] = []

    var body: some View {
        List(entries) { entry in
            NavigationLink(value: entry.book.ratingKey) {
                HStack(spacing: 12) {
                    CoverImage(thumb: entry.book.thumb)
                        .frame(width: 52, height: 52)
                        .clipShape(.rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.book.title)
                        if let author = entry.book.author {
                            Text(author)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }

                    Spacer()

                    // The stated position, and nothing invented where there is
                    // none. A book can be in a series without the agent knowing
                    // where it sits, and a made-up number would be worse than a
                    // blank — somebody would read it as the reading order.
                    if let position = entry.position {
                        Text(position)
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(series)
        .navigationDestination(for: String.self) { BookDetailView(ratingKey: $0) }
        .task { reload() }
        .onChange(of: app.libraryRevision) { _, _ in reload() }
    }

    private func reload() {
        guard let library = app.library else {
            entries = []
            return
        }
        entries = (try? library.books(inSeries: series, downloadedOnly: app.isOffline)) ?? []
    }
}

/// A route that is a series, not a book.
///
/// The same reason `GenreRoute` exists: this stack pushes both kinds, and a
/// series called "1234" would otherwise be the same destination as the book with
/// that rating key.
struct SeriesRoute: Hashable {
    let name: String
}
