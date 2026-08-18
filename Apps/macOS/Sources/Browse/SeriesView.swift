import SwiftUI
import Audiobooks
import PlatformShared

/// Series, from the metadata agent's own tags.
///
/// Shaped like `GenresView`: a grid of cards, and the books behind each in
/// reading order. The difference is that these have an *order* — the agent
/// records a position per book, and a series read out of order is the one
/// grouping where that matters.
///
/// Not from Plex collections. A collection is whatever somebody dragged into it,
/// in whatever order; a `Series:` Mood is something the metadata states. The
/// agent's contract is explicit that collections are user data and a series
/// should not be derived from them alone.
///
/// A card grid rather than a table, matching `AuthorsView` and `GenresView`:
/// a name and a count told you nothing until you clicked it, and the cover art
/// was already being fetched either way.
struct SeriesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var series: [SeriesSummary] = []

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)]

    var body: some View {
        // A `NavigationStack` of its own, for the reason `GenresView` explains:
        // this is shown in a column, and a column is not a stack.
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(series) { entry in
                        NavigationLink(value: SeriesRoute(name: entry.name)) {
                            SeriesTile(series: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Series")
            .navigationDestination(for: SeriesRoute.self) { SeriesBooksView(series: $0.name) }
            .overlay {
                if let activity = app.activity {
                    // Working, and saying so: this is a request per series, and
                    // an empty screen for a minute reads as a broken one. The
                    // "No series" message below is true only when nothing is
                    // being fetched.
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

/// A series as a card: its covers, its name, how many books are in it.
struct SeriesTile: View {
    let series: SeriesSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverCollage(thumbs: series.covers, placeholderSymbol: "books.vertical")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))

            Text(series.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.text)
                .lineLimit(2)

            Text(series.bookCount == 1 ? "1 book" : "\(series.bookCount) books")
                .font(.caption)
                .foregroundStyle(theme.tertiaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(series.name)
        .accessibilityValue(series.bookCount == 1 ? "1 book" : "\(series.bookCount) books")
    }
}

/// One series, in reading order.
///
/// Kept as a list rather than a grid, unlike the screen above it — reading
/// order is the entire point of a series, and a position stated plainly in a
/// column is a clearer answer to "what comes after this" than a number
/// badged onto a card would be.
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
        .background(theme.background)
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
